import Darwin
import Foundation

public struct JunkItem {
    /// Rule identifier, usable with `--only` and `--skip`.
    public let id: String
    public let category: JunkCategory
    public let title: String
    /// What gets removed.
    public let targets: [String]
    /// Empty the target folders instead of removing the folders themselves.
    public let contentsOnly: Bool
    /// Bytes on disk.
    public let size: Int64
    public let fileCount: Int
    public let safety: JunkSafety
    public let note: String?
    /// For project artifacts: when the project around it was last touched.
    public let lastUsed: Date?
    /// Part of it could not be read, so the size is a lower bound.
    public let partial: Bool

    public var displayPath: String {
        targets.count == 1 ? targets[0] : PathUtil.parent(targets[0]) + "/…"
    }
}

public struct JunkOptions {
    /// Folders searched for project build artifacts. Empty skips that search.
    public var projectRoots: [String] = []
    /// Look at the well-known cache locations in the home folder.
    public var includeKnownLocations = true
    /// Ignore anything smaller than this.
    public var minSize: Int64 = 10_000_000
    /// Only report project artifacts whose project was last touched at least this long ago.
    public var olderThan: TimeInterval?
    /// Artifacts of projects touched more recently than this are marked "review": you are
    /// probably still working there and would have to rebuild.
    public var activeWindow: TimeInterval = 7 * 86400
    public var threads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

    public init() {}
}

public struct JunkResult {
    public let items: [JunkItem]
    public let tree: FileTree

    /// Everything sapu is able to remove (safe and review items).
    public var removable: Int64 { items.filter { $0.safety != .info }.reduce(0) { $0 + $1.size } }
    public var safe: Int64 { items.filter { $0.safety == .safe }.reduce(0) { $0 + $1.size } }
}

/// Finds caches and regenerable build output.
public final class JunkFinder {
    private static let insideJunk: UInt8 = 1

    let options: JunkOptions
    let progress: ScanProgress?
    let home: String

    public init(options: JunkOptions = JunkOptions(), progress: ScanProgress? = nil, home: String = PathUtil.home) {
        self.options = options
        self.progress = progress
        self.home = home
    }

    public func run() -> JunkResult {
        var locations = options.includeKnownLocations ? KnownLocation.all(home: home) : []
        if options.includeKnownLocations {
            locations.append(contentsOf: sandboxCaches())
            locations.append(contentsOf: installers())
        }
        let locationPaths = locations.flatMap(\.paths).filter { JunkFinder.exists($0) }

        // Known locations are measured through their own roots; keep the project search out of them.
        var claimed: [String: Set<String>] = [:]
        for path in locationPaths {
            claimed[PathUtil.parent(path), default: []].insert(PathUtil.basename(path))
        }
        claimed[home, default: []].formUnion(["Library", "Applications"])

        var roots = locationPaths.map { WalkRoot(path: $0, context: JunkFinder.insideJunk) }
        let projectRoots = PathUtil.dedupeRoots(options.projectRoots).filter { root in
            !locationPaths.contains { PathUtil.isSameOrInside(root, $0) }
        }
        roots.append(contentsOf: projectRoots.map { WalkRoot(path: $0) })

        let walker = Walker()
        walker.threads = options.threads
        walker.progress = progress
        walker.classifier = { listing in
            // Inside junk everything counts; no further decisions to make.
            guard listing.context != JunkFinder.insideJunk else { return }
            let claimedHere = claimed[listing.path]
            for index in 0..<listing.count where listing.kind(index) == .dir {
                let name = listing.name(index)
                if let tag = ArtifactRule.tag(index: index, name: name, in: listing) {
                    listing.setTag(index, tag)
                    listing.setContext(index, JunkFinder.insideJunk)
                } else if name.hasPrefix(".") || name == "node_modules" || claimedHere?.contains(name) == true || JunkFinder.isBundle(name) {
                    // Hidden folders, app bundles and unowned node_modules are not projects.
                    listing.prune(index)
                }
            }
        }
        progress?.setPhase("scan")
        let tree = walker.scan(roots)

        var rootIndex: [String: Int32] = [:]
        for root in tree.roots { rootIndex[tree.path(root)] = root }

        var items: [JunkItem] = []
        for location in locations {
            let found = location.paths.compactMap { path in rootIndex[path].map { (path, $0) } }
            guard !found.isEmpty else { continue }
            switch location.mode {
            case .children:
                for (_, root) in found { items.append(contentsOf: childItems(of: root, location: location, tree: tree)) }
            case .contents, .item:
                let size = found.reduce(Int64(0)) { $0 + tree[$1.1].alloc }
                let unreadable = found.contains { !tree[$0.1].flags.isDisjoint(with: [.unreadable, .incomplete]) }
                guard size >= options.minSize || unreadable else { continue }
                items.append(JunkItem(
                    id: location.id, category: location.category, title: location.title,
                    targets: found.map(\.0), contentsOnly: location.mode == .contents,
                    size: size, fileCount: found.reduce(0) { $0 + Int(tree[$1.1].fileCount) },
                    safety: location.safety, note: location.note, lastUsed: nil, partial: unreadable
                ))
            }
        }
        items.append(contentsOf: artifactItems(tree))

        let order = Dictionary(uniqueKeysWithValues: JunkCategory.allCases.enumerated().map { ($1, $0) })
        items.sort { a, b in
            if a.category != b.category { return order[a.category]! < order[b.category]! }
            if a.size != b.size { return a.size > b.size }
            return a.displayPath < b.displayPath
        }
        return JunkResult(items: items, tree: tree)
    }

    // MARK: - Known locations

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isBundle(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return DupeFinder.bundleExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// Caches of sandboxed apps live inside each app's container.
    private func sandboxCaches() -> [KnownLocation] {
        let containers = home + "/Library/Containers"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: containers) else { return [] }
        return names.sorted().compactMap { name in
            // Docker's container is reported on its own; Apple's are managed by the system.
            guard !name.hasPrefix("com.apple."), name != "com.docker.docker" else { return nil }
            let caches = "\(containers)/\(name)/Data/Library/Caches"
            guard JunkFinder.exists(caches) else { return nil }
            return KnownLocation(id: "app-cache", category: .system, title: "Cache · \(name)", paths: [caches],
                                 safety: .safe, note: "Apps rebuild their caches when needed")
        }
    }

    private func installers() -> [KnownLocation] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") else { return [] }
        return names.sorted().filter { $0.hasPrefix("Install macOS") && $0.hasSuffix(".app") }.map { name in
            KnownLocation(id: "macos-installer", category: .large, title: String(name.dropLast(4)), paths: ["/Applications/" + name],
                          safety: .review, note: "macOS installer; download it again from the App Store if needed", mode: .item)
        }
    }

    private func childItems(of root: Int32, location: KnownLocation, tree: FileTree) -> [JunkItem] {
        guard tree[root].kind == .dir else { return [] }
        if tree[root].flags.contains(.unreadable) {
            return [JunkItem(id: location.id, category: location.category, title: location.title, targets: [tree.path(root)],
                             contentsOnly: true, size: 0, fileCount: 0, safety: .info, note: "Could not be read", lastUsed: nil, partial: true)]
        }
        var items: [JunkItem] = []
        for child in tree.children(root) {
            let node = tree[child]
            let name = tree.name(child)
            // Apple's own caches are managed (and often protected) by the system; Xcode's are fair game.
            if name.hasPrefix("com.apple.") && !name.hasPrefix("com.apple.dt.") { continue }
            let size = node.flags.contains(.sharedExtra) ? 0 : node.alloc
            guard size >= options.minSize, node.kind != .symlink else { continue }
            let label = KnownLocation.cacheLabels[name]
            items.append(JunkItem(
                id: location.id, category: location.category, title: label.map(\.title) ?? "\(location.title) · \(name)",
                targets: [tree.path(child)], contentsOnly: false,
                size: size, fileCount: Int(node.fileCount),
                safety: label?.safety ?? location.safety, note: label?.note ?? location.note,
                lastUsed: nil, partial: node.flags.contains(.incomplete)
            ))
        }
        return items
    }

    // MARK: - Project artifacts

    private func artifactItems(_ tree: FileTree) -> [JunkItem] {
        let now = Date()
        var items: [JunkItem] = []
        for index in 0..<Int32(tree.count) where tree[index].tag > 0 && tree[index].kind == .dir {
            let node = tree[index]
            guard node.alloc >= options.minSize, node.parent >= 0, let (rule, unpinned) = ArtifactRule.decode(tag: node.tag) else { continue }

            // A project is as fresh as the newest thing next to its build folder.
            var newest: Int64 = tree[node.parent].mtime
            for sibling in tree.children(node.parent) where tree[sibling].tag == 0 {
                newest = max(newest, tree[sibling].mtime)
            }
            let lastUsed = Date(timeIntervalSince1970: TimeInterval(newest))
            let idle = now.timeIntervalSince(lastUsed)
            if let olderThan = options.olderThan, idle < olderThan { continue }

            var safety = JunkSafety.safe
            var note = "Restore: \(rule.restore)"
            if let caution = rule.caution {
                safety = .review
                note = "\(caution). Restore: \(rule.restore)"
            } else if unpinned {
                safety = .review
                note = "No lockfile nearby, so a reinstall may pick different versions. Restore: \(rule.restore)"
            } else if idle < options.activeWindow {
                safety = .review
                note = "Project in active use; it would need: \(rule.restore)"
            }
            items.append(JunkItem(
                id: rule.id, category: .projects, title: rule.title,
                targets: [tree.path(index)], contentsOnly: false,
                size: node.alloc, fileCount: Int(node.fileCount),
                safety: safety, note: note, lastUsed: lastUsed, partial: node.flags.contains(.incomplete)
            ))
        }
        return items
    }
}

public enum JunkCleaner {
    public struct Outcome {
        public var removed = 0
        public var failures: [String] = []
    }

    /// Removes one junk item. Report-only items are refused.
    public static func clean(_ item: JunkItem, mode: RemoveMode, dryRun: Bool) -> Outcome {
        var outcome = Outcome()
        guard item.safety != .info else {
            outcome.failures.append("report only")
            return outcome
        }
        if item.category == .trash && mode == .trash {
            outcome.failures.append("already in the Trash; use --delete to empty it")
            return outcome
        }
        for target in item.targets {
            // What was measured was a real file or folder; if a link sits there now, leave it.
            var info = stat()
            if lstat(target, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                outcome.failures.append("\(target): is now a symbolic link")
                continue
            }
            var paths = [target]
            if item.contentsOnly {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: target) else {
                    outcome.failures.append("\(target): cannot be read")
                    continue
                }
                paths = names.map { target + "/" + $0 }
            }
            for path in paths {
                if dryRun {
                    outcome.removed += 1
                    continue
                }
                do {
                    try Remover.remove(path, mode: mode)
                    outcome.removed += 1
                } catch {
                    outcome.failures.append("\(path): \(error)")
                }
            }
        }
        return outcome
    }
}
