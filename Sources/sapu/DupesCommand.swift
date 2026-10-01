import Foundation
import SapuCore

enum DupesCommand {
    static let spec = ArgumentSpec(
        flags: ["files-only", "folders-only", "hidden", "all", "interactive", "trash", "delete", "clone",
                "dry-run", "yes", "json", "cross-device", "help"],
        options: ["min-size", "exclude", "keep", "prefer", "top", "threads"],
        short: ["i": "interactive", "n": "top", "y": "yes", "a": "all", "h": "help", "m": "min-size", "e": "exclude"]
    )

    static let help = """
    Find identical folders and files.

    USAGE
      sapu dupes [path ...] [options]

    With no path, your home folder is scanned. Nothing is changed unless you pass
    -i, --trash, --delete or --clone.

    WHAT TO REPORT
      -m, --min-size <size>   Ignore anything smaller (default 1M; e.g. 500k, 100M, 2G)
          --files-only        Only duplicate files
          --folders-only      Only duplicate folders
          --hidden            Include hidden files and look inside hidden folders
      -e, --exclude <name>    Skip entries by name, glob or absolute path (repeatable)
          --cross-device      Also scan other volumes mounted below the path
      -n, --top <count>       Groups to list (default 20)
      -a, --all               List every group
          --json              Machine-readable report

    WHICH COPY STAYS
          --keep <rule>       auto (default), oldest or newest
          --prefer <path>     Keep copies under this path when there is a choice (repeatable)

    WHAT TO DO
      -i, --interactive       Review the groups and tick what should go
          --trash             Move the copies marked "remove" to the Trash
          --delete            Delete them permanently
          --clone             Keep every path but store identical data once (APFS clones).
                              Quit apps that have those files open first.
          --dry-run           Show what would happen without doing it
      -y, --yes               Do not ask for confirmation

    SAFETY
      One verified copy of everything always stays, and nothing that changed since the scan
      is touched. Copies that belong to something larger (a git repository, a folder that is
      a variation of its twin's) are reported but only removed if you tick them yourself.
    """

    static func run(_ raw: [String]) throws -> Int32 {
        let arguments = try Arguments(raw, spec: spec)
        if arguments.has("help") {
            print(help)
            return 0
        }

        let actions = ["trash", "delete", "clone"].filter { arguments.has($0) }
        guard actions.count <= 1 else { throw UsageError(message: "choose only one of --trash, --delete, --clone") }
        guard !(arguments.has("files-only") && arguments.has("folders-only")) else {
            throw UsageError(message: "--files-only and --folders-only exclude each other")
        }
        let action = actions.first.flatMap { DupeAction(rawValue: $0) }
        let interactive = arguments.has("interactive")
        if arguments.has("json") && (interactive || action != nil) {
            throw UsageError(message: "--json only reports; it cannot be combined with -i or an action")
        }

        var policy = KeepPolicy()
        if let rule = arguments.value("keep") {
            guard let parsed = KeepPolicy.Rule(rawValue: rule) else { throw UsageError(message: "--keep must be auto, oldest or newest") }
            policy.rule = parsed
        }
        for path in arguments.values("prefer") {
            guard let resolved = PathUtil.normalize(path) else { throw UsageError(message: "--prefer: no such path: \(path)") }
            policy.prefer.append(resolved)
        }

        var options = DupeOptions()
        options.minSize = try arguments.size("min-size", default: options.minSize)
        options.includeFiles = !arguments.has("folders-only")
        options.includeFolders = !arguments.has("files-only")
        options.includeHidden = arguments.has("hidden")
        options.threads = max(1, try arguments.integer("threads", default: options.threads))
        let top = arguments.has("all") ? Int.max : try arguments.integer("top", default: 20)

        let roots = try arguments.roots(default: PathUtil.home)
        let excludes = arguments.values("exclude").map { $0.hasPrefix("/") || $0.hasPrefix("~") ? (PathUtil.normalize($0) ?? $0) : $0 }

        // Scan and compare.
        let progress = ScanProgress()
        let spinner = Spinner(progress)
        spinner.start()
        let walker = Walker()
        walker.threads = options.threads
        walker.crossDevices = arguments.has("cross-device")
        walker.progress = progress
        walker.classifier = ScanRules.dupes(excludes: excludes)
        let tree = walker.scan(roots.map { WalkRoot(path: $0) })
        let finder = DupeFinder(tree: tree, options: options, progress: progress)
        let result = finder.run(policy: policy)
        spinner.stop()

        if arguments.has("json") {
            print(Format.json(json(result, tree: tree, roots: roots)))
            return 0
        }

        let report = Report(tree: tree, finder: finder, result: result, roots: roots, options: options)
        report.printHeader()
        guard !result.groups.isEmpty else {
            print("No duplicates of \(Format.size(options.minSize)) or more. " + "Lower the bar with --min-size.".dim)
            Output.scanWarnings(tree)
            return 0
        }

        if interactive {
            return report.interact(action: action, dryRun: arguments.has("dry-run"), assumeYes: arguments.has("yes"))
        }

        let selections = report.defaultSelections(for: action ?? .trash)
        report.printGroups(selections: selections, limit: top, cloning: action == .clone)
        report.printSummary(selections: selections, cloning: action == .clone)
        Output.scanWarnings(tree)

        guard let action else {
            report.printNextSteps()
            return 0
        }
        if result.groups.count > top {
            print("This applies to all \(Format.count(result.groups.count)) groups, not only the \(top) listed. Add --all to see every one first.".yellow)
        }
        return report.perform(action, selections: selections, dryRun: arguments.has("dry-run"), assumeYes: arguments.has("yes"))
    }

    // MARK: - JSON

    private static func json(_ result: DupeResult, tree: FileTree, roots: [String]) -> [String: Any] {
        let groups: [[String: Any]] = result.groups.map { group in
            let removing = Set(group.suggested)
            return [
                "kind": group.kind.rawValue,
                "size": group.size,
                "files": group.fileCount,
                "reclaimable": group.reclaimable,
                "alreadyShared": group.shared,
                "sha256": group.digest.hex,
                "members": group.members.enumerated().map { index, member in
                    [
                        "path": member.path,
                        "suggestion": removing.contains(index) ? "remove" : "keep",
                        "hold": member.hold?.rawValue ?? NSNull(),
                        "modified": member.mtime,
                    ] as [String: Any]
                },
            ]
        }
        return [
            "roots": roots,
            "scanned": ["items": tree.count, "bytes": tree.roots.reduce(Int64(0)) { $0 + tree[$1].alloc }, "unreadable": tree.errorCount],
            "reclaimable": result.reclaimable,
            "alreadyShared": result.shared,
            "groups": groups,
        ]
    }
}

/// Everything needed to show duplicate groups and act on them.
private struct Report {
    let tree: FileTree
    let finder: DupeFinder
    let result: DupeResult
    let roots: [String]
    let options: DupeOptions

    var groups: [DupGroup] { result.groups }

    static func explain(_ hold: DupMember.Hold) -> String {
        switch hold {
        case .nested: return "inside another duplicate folder"
        case .repository: return "in a git repository"
        case .similarFolder: return "part of a folder that resembles its twin's"
        case .sibling: return "same folder, other name: likely on purpose"
        }
    }

    /// Paths are shown relative to the scanned folder when there is just one, which keeps lines short.
    func show(_ path: String) -> String {
        if roots.count == 1, roots[0] != PathUtil.home, roots[0] != "/", path.hasPrefix(roots[0] + "/") {
            return String(path.dropFirst(roots[0].count + 1))
        }
        return Format.path(path)
    }

    func printHeader() {
        let scanned = tree.roots.reduce(Int64(0)) { $0 + tree[$1].alloc }
        print("Duplicates in ".bold + roots.map(Format.path).joined(separator: ", ").bold)
        var line = "Scanned \(Format.count(tree.count)) items (\(Format.size(scanned))) in \(Format.seconds(tree.elapsed + result.stats.elapsed))"
        if result.stats.hashedBytes > 0 { line += " · read \(Format.size(result.stats.hashedBytes)) to compare contents" }
        print(line.dim)
        print("")
    }

    /// What each action applies to when the user did not choose by hand.
    func defaultSelections(for action: DupeAction) -> [Int: Set<Int>] {
        var selections: [Int: Set<Int>] = [:]
        for (index, group) in groups.enumerated() {
            var selected = Set(group.suggested)
            if action == .clone {
                // Cloning removes nothing, so copies inside repositories can take part too.
                let free = group.members.indices.filter { !group.members[$0].nested }
                let keeper = group.members.contains(where: \.nested) ? nil : free.first { !selected.contains($0) }
                selected = Set(free.filter { $0 != keeper })
            }
            if !selected.isEmpty { selections[index] = selected }
        }
        return selections
    }

    private func label(_ group: DupGroup) -> String {
        let copies = "×\(group.members.count)"
        switch group.kind {
        case .folder:
            return "FOLDER \(copies)  \(Format.size(group.size)) each · \(Format.plural(group.fileCount, "file"))"
        case .file:
            return "FILE \(copies)  \(Format.size(group.size)) each"
        }
    }

    func printGroups(selections: [Int: Set<Int>], limit: Int, cloning: Bool = false, onlySelected: Bool = false) {
        let width = min(Term.width(), 140)
        var removed = Set<String>()
        for (index, selected) in selections {
            for member in selected { removed.insert(groups[index].members[member].path) }
        }
        for (index, group) in groups.enumerated().prefix(limit) {
            let selected = selections[index] ?? []
            if onlySelected && selected.isEmpty { continue }
            let estimate = selected == Set(group.suggested) ? (group.reclaimable, group.shared) : finder.estimateReclaim(group, removing: selected)
            let number = String(index + 1).leftPadded(3)
            let left = "\(number)  \(label(group))"
            var right = ""
            if !selected.isEmpty {
                right = estimate.0 > 0 ? "\(cloning ? "saves" : "frees") \(Format.size(estimate.0))" : "frees nothing: storage is already shared"
            }
            let gap = max(2, width - left.count - right.count)
            print(left.bold + String(repeating: " ", count: gap) + (estimate.0 > 0 ? right.green : right.dim))

            // Copies that stay come first, then what goes.
            let order = group.members.indices.sorted { a, b in
                let ka = (selected.contains(a) ? 1 : 0, group.members[a].nested ? 1 : 0)
                let kb = (selected.contains(b) ? 1 : 0, group.members[b].nested ? 1 : 0)
                return ka != kb ? ka < kb : a < b
            }
            var goingWithParent = 0
            for memberIndex in order {
                let member = group.members[memberIndex]
                // A copy inside a folder that is itself going is already covered by that folder's line.
                if member.nested && DupePlanner.isGone(member.path, removed: removed) {
                    goingWithParent += 1
                    continue
                }
                let suffix = member.hold.map { "  (" + Report.explain($0) + ")" } ?? ""
                let path = show(member.path).middleTruncated(max(20, width - 14 - suffix.count))
                if selected.contains(memberIndex) {
                    print("     " + (cloning ? "clone  " : "remove ").yellow + " " + path + suffix.dim)
                } else {
                    print("     " + "keep   ".green + " " + path + suffix.dim)
                }
            }
            if goingWithParent > 0 {
                let copies = goingWithParent == 1 ? "1 copy" : "\(goingWithParent) copies"
                print("     … plus \(copies) inside folders marked for removal above".dim)
            }
        }
        if groups.count > limit {
            let rest = groups[limit...]
            let bytes = rest.reduce(Int64(0)) { $0 + $1.reclaimable }
            print("     … \(Format.plural(rest.count, "more group")) (\(Format.size(bytes)) reclaimable). List them with --all.".dim)
        }
        print("")
    }

    func printSummary(selections: [Int: Set<Int>], cloning: Bool = false) {
        var freed: Int64 = 0, shared: Int64 = 0, undecided: Int64 = 0
        for (index, group) in groups.enumerated() {
            let selected = selections[index] ?? []
            // Copies that stay although one would be enough: left for the user to judge.
            let staying = group.members.indices.filter { !group.members[$0].nested && !selected.contains($0) }.count
            let needed = group.members.contains(where: \.nested) ? 0 : 1
            undecided += group.size * Int64(max(0, staying - needed))
            guard !selected.isEmpty else { continue }
            let estimate = selected == Set(group.suggested) ? (group.reclaimable, group.shared) : finder.estimateReclaim(group, removing: selected)
            freed += estimate.0
            shared += estimate.1
        }
        print("\(Format.plural(groups.count, "duplicate group")) · " + "\(Format.size(freed)) can be \(cloning ? "saved" : "freed")".green.bold)
        if shared > 0 {
            print("  \(Format.size(shared)) more is duplicated in name only: clones and hard links already share their storage".dim)
        }
        if undecided > 0 && !cloning {
            print("  \(Format.size(undecided)) more sits in copies sapu will not pick for you (see the notes in brackets); tick them with -i".dim)
        }
    }

    func printNextSteps() {
        let target = roots == [PathUtil.home] ? "" : " " + roots.map { Format.path($0).contains(" ") ? "'\(Format.path($0))'" : Format.path($0) }.joined(separator: " ")
        print("")
        print("Nothing was changed. Next:".dim)
        print("  sapu dupes\(target) -i".bold + "        review and tick what should go".dim)
        print("  sapu dupes\(target) --trash".bold + "   move every copy marked \"remove\" to the Trash".dim)
        print("  sapu dupes\(target) --clone".bold + "   keep every path, store identical data once".dim)
    }

    // MARK: - Acting

    func perform(_ action: DupeAction, selections: [Int: Set<Int>], dryRun: Bool, assumeYes: Bool) -> Int32 {
        let count = selections.values.reduce(0) { $0 + $1.count }
        guard count > 0 else {
            print("Nothing to do.")
            return 0
        }
        let items = Format.plural(count, "item")
        if !dryRun && !assumeYes {
            let question: String
            switch action {
            case .trash: question = "Move \(items) to the Trash?"
            case .delete: question = "Permanently delete \(items)? This cannot be undone."
            case .clone: question = "Replace \(items) with space-sharing clones of their twin? Every path stays."
            }
            guard Term.stdinIsTTY else {
                Term.error("refusing to change anything without confirmation; add --yes to run unattended")
                return 1
            }
            guard Term.confirm("\n" + question.bold) else {
                print("Cancelled. Nothing was changed.")
                return 0
            }
        }

        print("")
        let executor = DupeExecutor(tree: tree, finder: finder, groups: groups)
        let summary = executor.execute(selections: selections, action: action, dryRun: dryRun) { outcome in
            let path = show(outcome.path)
            if outcome.succeeded {
                if let detail = outcome.detail, !detail.isEmpty { print("  ✓ \(path)  \(detail.dim)") }
            } else {
                print("  " + "skipped".yellow + " \(path)  " + (outcome.detail ?? "").dim)
            }
        }

        let amount = Format.size(summary.bytes)
        let prefix = dryRun ? "Dry run: would have " : ""
        switch action {
        case .trash:
            print((prefix.isEmpty ? "Moved " : prefix + "moved ") + "\(Format.plural(summary.done, "item")) to the Trash.".bold
                + " Empty the Trash to free about \(amount).")
        case .delete:
            print((prefix.isEmpty ? "Deleted " : prefix + "deleted ") + "\(Format.plural(summary.done, "item")).".bold + " About \(amount) freed.")
        case .clone:
            print((prefix.isEmpty ? "Cloned " : prefix + "cloned ") + "\(Format.plural(summary.done, "item")) in place.".bold
                + " About \(amount) is no longer stored twice.")
        }
        if summary.skipped > 0 {
            print("\(Format.plural(summary.skipped, "item")) skipped for safety; see above.".yellow)
        }
        return summary.skipped > 0 && summary.done == 0 ? 1 : 0
    }

    func interact(action: DupeAction?, dryRun: Bool, assumeYes: Bool) -> Int32 {
        guard Term.stdinIsTTY && Term.stdoutIsTTY else {
            Term.error("-i needs an interactive terminal")
            return 1
        }
        var rows: [PickerRow] = []
        var origin: [(group: Int, member: Int)?] = []
        let initial = defaultSelections(for: action ?? .trash)
        for (index, group) in groups.enumerated() {
            rows.append(PickerRow(kind: .header, text: "\(index + 1). \(label(group))", group: index))
            origin.append(nil)
            // Copies inside another duplicate folder are decided through that folder; list a couple for context.
            let nested = group.members.filter(\.nested)
            for member in nested.prefix(2) {
                rows.append(PickerRow(kind: .note, text: "also in \(show(member.path))  (part of another duplicate folder)", group: index))
                origin.append(nil)
            }
            if nested.count > 2 {
                rows.append(PickerRow(kind: .note, text: "… and \(nested.count - 2) more inside other duplicate folders", group: index))
                origin.append(nil)
            }
            for (memberIndex, member) in group.members.enumerated() where !member.nested {
                rows.append(PickerRow(
                    kind: .item,
                    text: show(member.path) + (member.hold.map { "  (" + Report.explain($0) + ")" } ?? ""),
                    trailing: Format.size(group.size),
                    checked: initial[index]?.contains(memberIndex) == true,
                    group: index
                ))
                origin.append((index, memberIndex))
            }
        }

        func selections(from rows: [PickerRow]) -> [Int: Set<Int>] {
            var result: [Int: Set<Int>] = [:]
            for (row, source) in zip(rows, origin) where row.checked {
                if let source { result[source.group, default: []].insert(source.member) }
            }
            return result
        }

        // Measuring a big folder group is not free; remember the answer per selection.
        var cache: [Int: (Set<Int>, Int64)] = [:]
        let picker = Picker(
            title: action == .clone ? "sapu dupes · tick the copies to turn into clones of their twin" : "sapu dupes · tick the copies that should go",
            rows: rows,
            verb: "Ticked",
            veto: { index, rows in
                let group = rows[index].group
                let hasNote = rows.contains { $0.group == group && $0.kind == .note }
                let stillKept = rows.indices.contains { $0 != index && rows[$0].group == group && rows[$0].kind == .item && !rows[$0].checked }
                return hasNote || stillKept ? nil : "One copy has to stay. Untick another one in this group first."
            },
            total: { rows in
                var bytes: Int64 = 0
                for (index, selected) in selections(from: rows) {
                    if let known = cache[index], known.0 == selected {
                        bytes += known.1
                    } else {
                        let freed = finder.estimateReclaim(groups[index], removing: selected).freed
                        cache[index] = (selected, freed)
                        bytes += freed
                    }
                }
                return bytes
            }
        )
        guard let final = picker.run() else {
            print("Cancelled. Nothing was changed.")
            return 0
        }
        let chosen = selections(from: final)
        let count = chosen.values.reduce(0) { $0 + $1.count }
        guard count > 0 else {
            print("Nothing ticked. Nothing was changed.")
            return 0
        }

        var decided = action
        if decided == nil {
            let prompt = "What should happen to the \(Format.plural(count, "ticked item"))?\n"
                + "  [t] move to Trash   [d] delete permanently   [c] replace with clones   [q] cancel\n>"
            switch Term.choose(prompt, among: ["t", "d", "c", "q"]) {
            case "t": decided = .trash
            case "d": decided = .delete
            case "c": decided = .clone
            default:
                print("Cancelled. Nothing was changed.")
                return 0
            }
        }
        printGroups(selections: chosen, limit: Int.max, cloning: decided == .clone, onlySelected: true)
        printSummary(selections: chosen, cloning: decided == .clone)
        // Choosing Trash or clones just now is confirmation enough; permanent deletion asks again.
        let confirmed = assumeYes || (action == nil && decided != .delete)
        return perform(decided!, selections: chosen, dryRun: dryRun, assumeYes: confirmed)
    }
}
