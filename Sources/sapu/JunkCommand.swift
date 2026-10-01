import Foundation
import SapuCore

enum Output {
    /// Mentions folders the scan could not read, and the usual fix.
    static func scanWarnings(_ tree: FileTree) {
        guard tree.errorCount > 0 else { return }
        print("")
        print("\(Format.plural(tree.errorCount, "folder")) could not be read, for example:".yellow)
        for error in tree.errors.prefix(3) {
            print("  \(Format.path(error.path))  \(error.message)".dim)
        }
        // EPERM is macOS privacy protection; plain permission errors are other users' files.
        if tree.errors.contains(where: { $0.code == EPERM }) {
            print("For complete results, allow your terminal under System Settings › Privacy & Security › Full Disk Access.".dim)
        }
    }
}

enum JunkCommand {
    static let spec = ArgumentSpec(
        flags: ["all", "interactive", "trash", "delete", "dry-run", "yes", "json", "review", "no-projects", "no-caches", "help"],
        options: ["min-size", "older-than", "only", "skip", "top", "threads"],
        short: ["i": "interactive", "n": "top", "y": "yes", "a": "all", "h": "help", "m": "min-size"]
    )

    static let help = """
    Find caches, build output and other data that can be regenerated.

    USAGE
      sapu junk [project-folder ...] [options]

    Looks at the well-known cache locations in your home folder, and searches the given
    folders (default: your home folder) for project build artifacts such as node_modules,
    target, .build or DerivedData. Nothing is changed unless you pass -i, --trash or --delete.

    Each finding is marked:
      ●  safe      rebuilt or re-downloaded automatically
      ◐  review    regenerable, but costly or with data attached; only removed with --review or -i
      ○  info      reported only, with the proper way to reclaim it

    WHAT TO REPORT
      -m, --min-size <size>    Ignore findings smaller than this (default 10M)
          --older-than <age>   Only build artifacts of projects untouched for this long (30d, 6m, 1y)
          --only <ids>         Only these rules or categories, comma separated (e.g. node_modules,xcode-derived-data)
          --skip <ids>         Leave these rules or categories out
          --no-projects        Do not search for project build artifacts
          --no-caches          Only search for project build artifacts
      -n, --top <count>        Findings to list per category (default 8)
      -a, --all                List everything
          --json               Machine-readable report

    WHAT TO DO
      -i, --interactive        Tick what should go
          --delete             Delete everything marked safe
          --trash              Move it to the Trash instead
          --review             Include the findings marked "review" as well
          --dry-run            Show what would happen without doing it
      -y, --yes                Do not ask for confirmation
    """

    static func run(_ raw: [String]) throws -> Int32 {
        let arguments = try Arguments(raw, spec: spec)
        if arguments.has("help") {
            print(help)
            return 0
        }
        guard !(arguments.has("trash") && arguments.has("delete")) else { throw UsageError(message: "choose either --trash or --delete") }
        let mode: RemoveMode? = arguments.has("delete") ? .delete : arguments.has("trash") ? .trash : nil
        let interactive = arguments.has("interactive")
        if arguments.has("json") && (interactive || mode != nil) {
            throw UsageError(message: "--json only reports; it cannot be combined with -i or an action")
        }

        var options = JunkOptions()
        options.minSize = try arguments.size("min-size", default: options.minSize)
        options.includeKnownLocations = !arguments.has("no-caches")
        options.threads = max(1, try arguments.integer("threads", default: options.threads))
        if let age = arguments.value("older-than") {
            guard let seconds = DurationText.parse(age) else { throw UsageError(message: "--older-than: '\(age)' is not an age (try 30d, 6m, 1y)") }
            options.olderThan = seconds
        }
        if !arguments.has("no-projects") {
            options.projectRoots = try arguments.roots(default: PathUtil.home)
        } else if !arguments.positionals.isEmpty {
            throw UsageError(message: "--no-projects cannot be combined with project folders")
        }
        let top = arguments.has("all") ? Int.max : try arguments.integer("top", default: 8)

        func idList(_ option: String) -> Set<String> {
            Set(arguments.values(option).flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } })
        }
        let only = idList("only"), skip = idList("skip")
        func matches(_ item: JunkItem, _ ids: Set<String>) -> Bool {
            ids.contains(item.id.lowercased()) || ids.contains(categoryKey(item.category))
        }

        let progress = ScanProgress()
        let spinner = Spinner(progress)
        spinner.start()
        let result = JunkFinder(options: options, progress: progress).run()
        spinner.stop()

        let items = result.items.filter { (only.isEmpty || matches($0, only)) && !matches($0, skip) }

        if arguments.has("json") {
            print(Format.json(json(items, tree: result.tree)))
            return 0
        }

        print("Junk: caches, build output and other regenerable data".bold)
        print("Scanned \(Format.count(result.tree.count)) items in \(Format.seconds(result.tree.elapsed))".dim)
        print("")
        guard !items.isEmpty else {
            print("Nothing of \(Format.size(options.minSize)) or more found.")
            return 0
        }

        if interactive {
            return interact(items, mode: mode, dryRun: arguments.has("dry-run"), assumeYes: arguments.has("yes"))
        }

        printItems(items, limit: top)
        printTotals(items)

        guard let mode else {
            print("")
            print("Nothing was changed. Next:".dim)
            print("  sapu junk -i".bold + "         tick what should go".dim)
            print("  sapu junk --delete".bold + "   delete everything marked ● safe".dim)
            return 0
        }
        let chosen = items.filter { $0.size > 0 && ($0.safety == .safe || ($0.safety == .review && arguments.has("review"))) }
        return perform(chosen, mode: mode, dryRun: arguments.has("dry-run"), assumeYes: arguments.has("yes"))
    }

    /// `Project build artifacts` → `projects`, so categories can be named in --only and --skip.
    private static func categoryKey(_ category: JunkCategory) -> String {
        String(describing: category)
    }

    private static func marker(_ safety: JunkSafety) -> String {
        switch safety {
        case .safe: return "●".green
        case .review: return "◐".yellow
        case .info: return "○".dim
        }
    }

    private static func describe(_ item: JunkItem) -> String {
        var text = item.title
        if item.category == .projects, let lastUsed = item.lastUsed {
            text += " · project touched " + DurationText.ago(Date().timeIntervalSince(lastUsed))
        }
        return text
    }

    private static func printItems(_ items: [JunkItem], limit: Int) {
        let width = min(Term.width(), 140)
        for category in JunkCategory.allCases {
            let group = items.filter { $0.category == category }
            guard !group.isEmpty else { continue }
            let total = group.reduce(Int64(0)) { $0 + $1.size }
            let title = "\(category.rawValue)  [\(categoryKey(category))]"
            print(title.bold + String(repeating: " ", count: max(2, width - title.count - 10)) + Format.size(total).leftPadded(10).bold)

            for item in group.prefix(limit) {
                let size = item.partial && item.size == 0 ? "?".leftPadded(9) : Format.size(item.size).leftPadded(9)
                // Projects are recognised by their path, everything else by its name.
                var primary = item.title, secondary = Format.path(item.displayPath)
                if category == .projects {
                    primary = Format.path(item.displayPath)
                    secondary = item.title + (item.lastUsed.map { " · " + DurationText.ago(Date().timeIntervalSince($0)) } ?? "")
                }
                let room = width - 14
                secondary = secondary.middleTruncated(max(16, room - min(primary.count, room * 6 / 10) - 2))
                primary = primary.middleTruncated(max(16, room - secondary.count - 2))
                let gap = max(2, room - primary.count - secondary.count)
                print(" \(marker(item.safety)) \(size)  \(primary)" + String(repeating: " ", count: gap) + secondary.dim)
                var notes: [String] = []
                if item.partial { notes.append("could not be read completely; your terminal may need Full Disk Access") }
                if item.safety != .safe, let note = item.note { notes.append(note) }
                for note in notes { print("              " + note.dim) }
            }
            if group.count > limit {
                let rest = group.dropFirst(limit)
                print("              … \(Format.plural(rest.count, "more finding")) (\(Format.size(rest.reduce(Int64(0)) { $0 + $1.size }))). List them with --all.".dim)
            }
            print("")
        }
    }

    private static func printTotals(_ items: [JunkItem]) {
        func total(_ safety: JunkSafety) -> Int64 { items.filter { $0.safety == safety }.reduce(0) { $0 + $1.size } }
        var parts = ["● safe to remove: \(Format.size(total(.safe)))".green.bold]
        if total(.review) > 0 { parts.append("◐ worth a review: \(Format.size(total(.review)))".yellow) }
        if total(.info) > 0 { parts.append("○ reported only: \(Format.size(total(.info)))".dim) }
        print(parts.joined(separator: "   "))
    }

    private static func perform(_ items: [JunkItem], mode: RemoveMode, dryRun: Bool, assumeYes: Bool) -> Int32 {
        // The Trash cannot be moved to the Trash.
        let items = mode == .trash ? items.filter { $0.category != .trash } : items
        guard !items.isEmpty else {
            print("Nothing to do.")
            return 0
        }
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        let summary = "\(Format.plural(items.count, "finding")) (\(Format.size(bytes)))"
        if !dryRun && !assumeYes {
            guard Term.stdinIsTTY else {
                Term.error("refusing to change anything without confirmation; add --yes to run unattended")
                return 1
            }
            let question = mode == .delete ? "Permanently delete \(summary)? This cannot be undone." : "Move \(summary) to the Trash?"
            guard Term.confirm("\n" + question.bold) else {
                print("Cancelled. Nothing was changed.")
                return 0
            }
        }

        print("")
        let before = VolumeInfo.of(path: PathUtil.home)?.free
        var freed: Int64 = 0
        var failed = 0
        for item in items {
            let label = "\(describe(item))  \(Format.path(item.displayPath))"
            if Term.stdoutIsTTY && !dryRun {
                print("  … \(label.middleTruncated(max(20, Term.width() - 6)))", terminator: "")
                fflush(stdout)
            }
            let outcome = JunkCleaner.clean(item, mode: mode, dryRun: dryRun)
            if Term.stdoutIsTTY && !dryRun { print("\r\u{1B}[2K", terminator: "") }
            if outcome.failures.isEmpty {
                freed += item.size
                print("  ✓ ".green + Format.size(item.size).leftPadded(9) + "  \(label)")
            } else {
                failed += 1
                if outcome.removed > 0 { freed += item.size }
                print("  ! ".yellow + Format.size(item.size).leftPadded(9) + "  \(label)")
                for failure in outcome.failures.prefix(3) { print("              \(Format.path(failure))".dim) }
                if outcome.failures.count > 3 { print("              … and \(outcome.failures.count - 3) more".dim) }
            }
        }

        print("")
        if dryRun {
            print("Dry run: would have removed about \(Format.size(freed)).".bold + " Nothing was changed.")
        } else if mode == .trash {
            print("Moved about \(Format.size(freed)) to the Trash.".bold + " Empty the Trash to actually free the space.")
        } else {
            var line = "Deleted about \(Format.size(freed)).".bold
            if let before, let after = VolumeInfo.of(path: PathUtil.home)?.free {
                line += " Free space: \(Format.size(before)) → \(Format.size(after))."
            }
            print(line)
        }
        if failed > 0 {
            print("\(Format.plural(failed, "finding")) could not be removed completely; see above.".yellow)
        }
        return 0
    }

    private static func interact(_ items: [JunkItem], mode: RemoveMode?, dryRun: Bool, assumeYes: Bool) -> Int32 {
        guard Term.stdinIsTTY && Term.stdoutIsTTY else {
            Term.error("-i needs an interactive terminal")
            return 1
        }
        var rows: [PickerRow] = []
        var origin: [Int?] = []
        for (number, category) in JunkCategory.allCases.enumerated() {
            let indexes = items.indices.filter { items[$0].category == category && items[$0].safety != .info && items[$0].size > 0 }
            guard !indexes.isEmpty else { continue }
            let total = indexes.reduce(Int64(0)) { $0 + items[$1].size }
            rows.append(PickerRow(kind: .header, text: category.rawValue, trailing: Format.size(total), group: number))
            origin.append(nil)
            for index in indexes {
                let item = items[index]
                let flag = item.safety == .review ? "◐ " : ""
                rows.append(PickerRow(
                    kind: .item,
                    text: "\(flag)\(describe(item))  \(Format.path(item.displayPath))",
                    trailing: Format.size(item.size),
                    checked: item.safety == .safe,
                    group: number,
                    bytes: item.size
                ))
                origin.append(index)
                if item.safety == .review, let note = item.note {
                    rows.append(PickerRow(kind: .note, text: note, group: number))
                    origin.append(nil)
                }
            }
        }
        guard rows.contains(where: { $0.kind == .item }) else {
            print("Nothing here can be removed by sapu; see the report without -i for advice.")
            return 0
        }

        let picker = Picker(title: "sapu junk · tick what should go  (◐ = review first)", rows: rows, verb: "Ticked")
        guard let final = picker.run() else {
            print("Cancelled. Nothing was changed.")
            return 0
        }
        let chosen = zip(final, origin).compactMap { row, index in row.checked ? index.map { items[$0] } : nil }
        guard !chosen.isEmpty else {
            print("Nothing ticked. Nothing was changed.")
            return 0
        }

        var decided = mode
        if decided == nil {
            let bytes = chosen.reduce(Int64(0)) { $0 + $1.size }
            let prompt = "\(Format.plural(chosen.count, "finding")) ticked (\(Format.size(bytes))).\n"
                + "  [d] delete permanently   [t] move to Trash   [q] cancel\n>"
            switch Term.choose(prompt, among: ["d", "t", "q"]) {
            case "d": decided = .delete
            case "t": decided = .trash
            default:
                print("Cancelled. Nothing was changed.")
                return 0
            }
        }
        // Ticking by hand and then choosing what to do is confirmation enough.
        return perform(chosen, mode: decided!, dryRun: dryRun, assumeYes: assumeYes || mode == nil)
    }

    private static func json(_ items: [JunkItem], tree: FileTree) -> [String: Any] {
        [
            "scanned": ["items": tree.count, "unreadable": tree.errorCount],
            "safe": items.filter { $0.safety == .safe }.reduce(Int64(0)) { $0 + $1.size },
            "review": items.filter { $0.safety == .review }.reduce(Int64(0)) { $0 + $1.size },
            "findings": items.map { item in
                var entry: [String: Any] = [
                    "id": item.id,
                    "category": categoryKey(item.category),
                    "title": item.title,
                    "paths": item.targets,
                    "size": item.size,
                    "files": item.fileCount,
                    "safety": item.safety.rawValue,
                    "partial": item.partial,
                ]
                if let note = item.note { entry["note"] = note }
                if let lastUsed = item.lastUsed { entry["projectLastTouched"] = Int(lastUsed.timeIntervalSince1970) }
                return entry
            },
        ]
    }
}
