import Darwin
import Foundation

public enum DupeAction: String {
    case trash, delete
    /// Keep every path but store the bytes once (APFS clones).
    case clone
}

public struct DupeOutcome {
    public let path: String
    public let group: Int
    public let succeeded: Bool
    /// Why it was skipped, or a note about what was done.
    public let detail: String?
}

public struct DupeSummary {
    public var done = 0
    public var skipped = 0
    /// Estimated bytes freed (or, for clones, no longer stored twice).
    public var bytes: Int64 = 0
}

/// Carries out a selection of duplicates to remove or clone.
///
/// Nothing is touched unless, at that moment, a different copy from the same group still exists
/// and both it and the item are unchanged since they were compared.
public final class DupeExecutor {
    let tree: FileTree
    let finder: DupeFinder
    let groups: [DupGroup]

    public init(tree: FileTree, finder: DupeFinder, groups: [DupGroup]) {
        self.tree = tree
        self.finder = finder
        self.groups = groups
    }

    /// - Parameter selections: member indexes to act on, per group index.
    public func execute(
        selections: [Int: Set<Int>],
        action: DupeAction,
        dryRun: Bool,
        report: (DupeOutcome) -> Void
    ) -> DupeSummary {
        var summary = DupeSummary()
        var removed = Set<String>()
        if action != .clone {
            for (group, selected) in selections {
                for member in selected { removed.insert(groups[group].members[member].path) }
            }
        }

        for groupIndex in selections.keys.sorted() {
            guard let selected = selections[groupIndex], !selected.isEmpty else { continue }
            let group = groups[groupIndex]
            var completed = Set<Int>()

            func skip(_ member: Int, _ reason: String) {
                summary.skipped += 1
                report(DupeOutcome(path: group.members[member].path, group: groupIndex, succeeded: false, detail: reason))
            }

            for member in selected.sorted() {
                let item = group.members[member]
                // The copy that stays is looked up afresh for every removal: not selected, not inside
                // anything being removed, still intact, and a different object from the item.
                var sameObject = false
                let keeper = group.members.indices.first { index in
                    guard !selected.contains(index), !DupePlanner.isGone(group.members[index].path, removed: removed),
                          tree.changeSinceScan(group.members[index].node) == nil else { return false }
                    if DupeExecutor.isSameObject(group.members[index].path, item.path) {
                        sameObject = true
                        return false
                    }
                    return true
                }
                guard let keeper else {
                    skip(member, sameObject ? "the other copy is this very item under another path" : "no verified copy would remain")
                    continue
                }
                if let difference = tree.changeSinceScan(item.node) {
                    skip(member, "changed since the scan (\(difference))")
                    continue
                }
                switch action {
                case .trash, .delete:
                    if let reason = Guardrails.refusal(for: item.path) {
                        skip(member, "refused: \(reason)")
                        continue
                    }
                    if !dryRun {
                        if let mismatch = unconfirmedDifference(group: group, keeper: keeper, member: member) {
                            skip(member, mismatch)
                            continue
                        }
                        do {
                            try Remover.remove(item.path, mode: action == .trash ? .trash : .delete)
                        } catch {
                            skip(member, "\(error)")
                            continue
                        }
                    }
                    completed.insert(member)
                    summary.done += 1
                    report(DupeOutcome(path: item.path, group: groupIndex, succeeded: true, detail: nil))
                case .clone:
                    let result = clone(group: group, keeper: keeper, member: member, dryRun: dryRun)
                    summary.bytes += result.bytes
                    if result.cloned == 0 && result.failed > 0 {
                        skip(member, result.firstFailure ?? "could not be cloned")
                        continue
                    }
                    summary.done += 1
                    report(DupeOutcome(path: item.path, group: groupIndex, succeeded: true, detail: result.note))
                }
            }
            if action != .clone && !completed.isEmpty {
                summary.bytes += finder.estimateReclaim(group, removing: completed).freed
            }
        }
        return summary
    }

    /// True when both paths are one and the same item, so that removing one removes "both".
    /// Two hard-linked names of a file do not count: the file survives under its other name.
    static func isSameObject(_ a: String, _ b: String) -> Bool {
        var first = stat(), second = stat()
        guard lstat(a, &first) == 0, lstat(b, &second) == 0 else { return false }
        guard first.st_dev == second.st_dev, first.st_ino == second.st_ino else { return false }
        return !(first.st_mode & S_IFMT == S_IFREG && first.st_nlink >= 2)
    }

    /// Files that were matched by clone ID were never read. Before one of them is removed, its
    /// bytes are compared with the copy that stays; returns what differs, or nil if all is well.
    private func unconfirmedDifference(group: DupGroup, keeper: Int, member: Int) -> String? {
        var problem: String?
        func confirm(_ files: [Int32]) {
            guard problem == nil, !(finder.wasRead(files[0]) && finder.wasRead(files[1])) else { return }
            let kept = tree.path(files[0]), going = tree.path(files[1])
            // Hard links are one file; there is nothing to compare.
            if PathUtil.sameObject(kept, going) { return }
            if !FileHasher.contentsEqual(kept, going) { problem = "differs from the copy that stays (\(kept))" }
        }
        let pair = [group.members[keeper].node, group.members[member].node]
        if group.kind == .file {
            confirm(pair)
        } else {
            finder.forEachAlignedFile(pair, onMismatch: { problem = "folders no longer line up" }, confirm)
        }
        return problem
    }

    private struct CloneResult {
        var cloned = 0
        var alreadyShared = 0
        var failed = 0
        var bytes: Int64 = 0
        var firstFailure: String?

        var note: String {
            var parts: [String] = []
            if cloned > 0 { parts.append(cloned == 1 ? "1 file now shares storage" : "\(cloned) files now share storage") }
            if alreadyShared > 0 { parts.append("\(alreadyShared) already shared") }
            if failed > 0 { parts.append("\(failed) skipped" + (firstFailure.map { " (\($0))" } ?? "")) }
            return parts.joined(separator: ", ")
        }
    }

    private func clone(group: DupGroup, keeper: Int, member: Int, dryRun: Bool) -> CloneResult {
        var result = CloneResult()
        func cloneFile(_ files: [Int32]) {
            let source = tree.nodes[Int(files[0])], target = tree.nodes[Int(files[1])]
            if target.size == 0 { return }
            if source.dev == target.dev && source.cloneID == target.cloneID {
                result.alreadyShared += 1
                return
            }
            if dryRun {
                result.cloned += 1
                result.bytes += target.alloc
                return
            }
            do {
                result.bytes += try Cloner.replaceWithClone(source: tree.path(files[0]), target: tree.path(files[1]))
                result.cloned += 1
            } catch {
                result.failed += 1
                if result.firstFailure == nil { result.firstFailure = "\(error)" }
            }
        }

        let pair = [group.members[keeper].node, group.members[member].node]
        if group.kind == .file {
            cloneFile(pair)
        } else {
            finder.forEachAlignedFile(pair, onMismatch: {
                result.failed += 1
                if result.firstFailure == nil { result.firstFailure = "folders no longer line up" }
            }, cloneFile)
        }
        return result
    }
}
