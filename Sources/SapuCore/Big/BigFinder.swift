import Foundation

public struct BigEntry {
    public let node: Int32
    public let name: String
    public let kind: NodeKind
    /// Bytes on disk, counting storage shared between files once.
    public let size: Int64
    public let fileCount: Int
    /// Could not be read completely; the size is a lower bound.
    public let partial: Bool
    public var children: [BigEntry] = []
    /// Entries left out of `children` because they were too small to list.
    public var omittedCount = 0
    public var omittedSize: Int64 = 0
}

public enum BigFinder {
    /// The `limit` largest files in the tree, by space on disk.
    public static func largestFiles(_ tree: FileTree, limit: Int) -> [(path: String, size: Int64)] {
        var floor: Int64 = 1 << 20
        var found: [(Int32, Int64)] = []
        while true {
            found.removeAll(keepingCapacity: true)
            for index in 0..<tree.count {
                let node = tree.nodes[index]
                if node.kind == .file && node.alloc >= floor && !node.flags.contains(.sharedExtra) {
                    found.append((Int32(index), node.alloc))
                }
            }
            if found.count >= limit || floor == 0 { break }
            floor = floor > 4096 ? floor / 16 : 0
        }
        found.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return found.prefix(limit).map { (tree.path($0.0), $0.1) }
    }

    /// The biggest entries below `root`, `depth` levels deep, at most `limit` per folder.
    /// Entries under `minFraction` of the root's size are summed up instead of listed.
    public static func breakdown(_ tree: FileTree, root: Int32, depth: Int, limit: Int, minFraction: Double = 0.01) -> BigEntry {
        let threshold = Int64(Double(tree[root].alloc) * minFraction)
        return entry(tree, root, depth: depth, limit: limit, threshold: threshold, isRoot: true)
    }

    private static func size(_ node: Node) -> Int64 {
        node.flags.contains(.sharedExtra) ? 0 : node.alloc
    }

    private static func entry(_ tree: FileTree, _ index: Int32, depth: Int, limit: Int, threshold: Int64, isRoot: Bool) -> BigEntry {
        let node = tree[index]
        var result = BigEntry(
            node: index,
            name: isRoot ? tree.path(index) : tree.name(index),
            kind: node.kind,
            size: size(node),
            fileCount: Int(node.fileCount),
            partial: !node.flags.isDisjoint(with: [.unreadable, .incomplete, .pruned, .mount])
        )
        guard node.kind == .dir, depth > 0 else { return result }

        let sorted = tree.children(index).sorted { a, b in
            let sa = size(tree[a]), sb = size(tree[b])
            return sa != sb ? sa > sb : a < b
        }
        for (position, child) in sorted.enumerated() {
            let childSize = size(tree[child])
            if position < limit && childSize >= max(threshold, 1) {
                result.children.append(entry(tree, child, depth: depth - 1, limit: limit, threshold: threshold, isRoot: false))
            } else if position < min(limit, 3) && childSize >= max(threshold / 10, 1) {
                // Always name the top few, so a folder of many small things is not a blank.
                result.children.append(entry(tree, child, depth: 0, limit: limit, threshold: threshold, isRoot: false))
            } else {
                result.omittedCount += 1
                result.omittedSize += childSize
            }
        }
        return result
    }
}
