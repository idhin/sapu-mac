import Foundation
import SapuCore

enum BigCommand {
    static let spec = ArgumentSpec(
        flags: ["json", "cross-device", "help"],
        options: ["depth", "top", "files", "threads"],
        short: ["d": "depth", "n": "top", "f": "files", "h": "help"]
    )

    static let help = """
    Show what is taking the space.

    USAGE
      sapu big [path ...] [options]

    With no path, your home folder is measured. Sizes are space on disk; data that several
    files share (APFS clones, hard links) is counted once. Nothing is ever changed.

    OPTIONS
      -d, --depth <levels>   Levels of folders to show (default 2)
      -n, --top <count>      Entries per folder (default 8)
      -f, --files <count>    Largest single files to list (default 15, 0 to hide)
          --cross-device     Also measure other volumes mounted below the path
          --json             Machine-readable report
    """

    static func run(_ raw: [String]) throws -> Int32 {
        let arguments = try Arguments(raw, spec: spec)
        if arguments.has("help") {
            print(help)
            return 0
        }
        let depth = try arguments.integer("depth", default: 2)
        let top = try arguments.integer("top", default: 8)
        let fileCount = try arguments.integer("files", default: 15)
        let roots = try arguments.roots(default: PathUtil.home)

        let progress = ScanProgress()
        let spinner = Spinner(progress)
        spinner.start()
        let walker = Walker()
        walker.threads = max(1, try arguments.integer("threads", default: walker.threads))
        walker.crossDevices = arguments.has("cross-device")
        walker.progress = progress
        let tree = walker.scan(roots.map { WalkRoot(path: $0) })
        spinner.stop()

        let breakdowns = tree.roots.map { BigFinder.breakdown(tree, root: $0, depth: depth, limit: top) }
        let files = fileCount > 0 ? BigFinder.largestFiles(tree, limit: fileCount) : []

        if arguments.has("json") {
            func encode(_ entry: BigEntry) -> [String: Any] {
                var object: [String: Any] = ["name": entry.name, "size": entry.size, "files": entry.fileCount, "partial": entry.partial]
                if !entry.children.isEmpty { object["children"] = entry.children.map(encode) }
                if entry.omittedCount > 0 { object["omitted"] = ["count": entry.omittedCount, "size": entry.omittedSize] }
                return object
            }
            print(Format.json([
                "scanned": ["items": tree.count, "unreadable": tree.errorCount],
                "roots": breakdowns.map(encode),
                "largestFiles": files.map { ["path": $0.path, "size": $0.size] as [String: Any] },
            ]))
            return 0
        }

        print("Space used in ".bold + roots.map(Format.path).joined(separator: ", ").bold)
        print("Scanned \(Format.count(tree.count)) items in \(Format.seconds(tree.elapsed))".dim)
        print("")
        for root in breakdowns {
            printTree(root, total: max(root.size, 1))
            print("")
        }
        if !files.isEmpty {
            print("Largest files".bold)
            let width = min(Term.width(), 140)
            for file in files {
                print(Format.size(file.size).leftPadded(10) + "  " + Format.path(file.path).middleTruncated(max(20, width - 13)))
            }
        }
        Output.scanWarnings(tree)
        return 0
    }

    private static func printTree(_ root: BigEntry, total: Int64) {
        let width = min(Term.width(), 140)
        let barWidth = 16
        print(Format.size(root.size).leftPadded(10).bold + "  " + Format.path(root.name).bold + (root.partial ? "  (partly unreadable)".dim : ""))

        func walk(_ entry: BigEntry, prefix: String) {
            var lines: [(size: Int64, name: String, node: BigEntry?)] = entry.children.map { ($0.size, $0.name, $0) }
            if entry.omittedCount > 0 {
                lines.append((entry.omittedSize, "(\(Format.plural(entry.omittedCount, "smaller item")))", nil))
            }
            for (position, line) in lines.enumerated() {
                let last = position == lines.count - 1
                let branch = prefix + (last ? "└─ " : "├─ ")
                let fraction = Double(line.size) / Double(total)
                let percent = String(format: "%4.1f%%", fraction * 100)
                var name = line.name
                if let node = line.node {
                    if node.kind == .dir { name += "/" }
                    if node.partial { name += " *" }
                }
                let room = max(12, width - 10 - 2 - branch.count - barWidth - 9)
                let shown = name.middleTruncated(room).rightPadded(room)
                let text = Format.size(line.size).leftPadded(10) + "  " + branch.dim + (line.node == nil ? shown.dim : shown)
                print(text + " " + Format.bar(fraction: fraction, width: barWidth).cyan + " " + percent.dim)
                if let node = line.node, !node.children.isEmpty || node.omittedCount > 0 {
                    walk(node, prefix: prefix + (last ? "   " : "│  "))
                }
            }
        }
        walk(root, prefix: "")
        if containsPartial(root) { print("            * could not be read completely; the real size is larger".dim) }
    }

    private static func containsPartial(_ entry: BigEntry) -> Bool {
        entry.children.contains { $0.partial || containsPartial($0) }
    }
}
