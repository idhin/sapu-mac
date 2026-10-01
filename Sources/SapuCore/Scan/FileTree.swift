import Darwin
import Foundation

public enum NodeKind: UInt8 {
    case file, dir, symlink, other
}

public struct NodeFlags: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Directory that could not be listed (permissions, TCC, I/O error).
    public static let unreadable = NodeFlags(rawValue: 1 << 0)
    /// Skipped on purpose by a scan rule; its contents are unknown.
    public static let pruned = NodeFlags(rawValue: 1 << 1)
    /// Cloud placeholder whose data is not on this disk.
    public static let dataless = NodeFlags(rawValue: 1 << 2)
    /// Hard-linked or cloned: its storage may also be reachable through another node.
    public static let maybeShared = NodeFlags(rawValue: 1 << 3)
    /// Storage already counted on an earlier node; excluded from directory totals.
    public static let sharedExtra = NodeFlags(rawValue: 1 << 4)
    /// Directory with an unreadable, pruned or dataless descendant.
    public static let incomplete = NodeFlags(rawValue: 1 << 5)
    /// Lives on another volume that the scan did not cross into.
    public static let mount = NodeFlags(rawValue: 1 << 6)
    /// File with a resource fork: content that lives outside the regular data.
    public static let resourceFork = NodeFlags(rawValue: 1 << 7)
}

/// One file system entry. Kept compact: a home directory easily has millions of them.
public struct Node {
    public var parent: Int32
    var nameOffset: UInt32
    public var childStart: Int32
    public var childCount: Int32
    /// Logical bytes. Directories hold the recursive total once `aggregate()` ran.
    public var size: Int64
    /// Bytes allocated on disk. Directories hold the recursive total, counting shared storage once.
    public var alloc: Int64
    public var mtime: Int64
    public var inode: UInt64
    /// Identifies the data stream: clones and hard links of one file share it.
    public var cloneID: UInt64
    /// Regular files at or below this node.
    public var fileCount: Int32
    /// Sub-second part of `mtime`, so an edit within the same second still shows as a change.
    var mtimeNanos: UInt32 = 0
    var nameLength: UInt16
    public var kind: NodeKind
    public var flags: NodeFlags
    /// Index into `FileTree.devices`.
    public var dev: UInt8
    /// Free for scan classifiers (for example the junk rule that matched).
    public var tag: UInt8
}

public struct ScanError {
    public let path: String
    public let code: Int32
    public var message: String { String(cString: strerror(code)) }
}

/// In-memory snapshot of the scanned directory trees.
public final class FileTree {
    public internal(set) var nodes: [Node] = []
    var nameArena: [UInt8] = []
    public internal(set) var roots: [Int32] = []
    public internal(set) var devices: [Int32] = []
    public internal(set) var errors: [ScanError] = []
    public internal(set) var errorCount = 0
    public internal(set) var elapsed: TimeInterval = 0

    /// Directories already entered, by device and inode. A directory that turns up a second time
    /// (a firmlink, the same volume mounted twice) is an alias, not a copy, and is not entered again.
    var entered = Set<ObjectID>()

    static let maxRecordedErrors = 200

    public init() {}

    public var count: Int { nodes.count }

    public subscript(_ index: Int32) -> Node { nodes[Int(index)] }

    public func name(_ index: Int32) -> String {
        let node = nodes[Int(index)]
        let start = Int(node.nameOffset)
        return String(decoding: nameArena[start..<start + Int(node.nameLength)], as: UTF8.self)
    }

    func withNameBytes<R>(_ index: Int32, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let node = nodes[Int(index)]
        return nameArena.withUnsafeBufferPointer { arena in
            body(UnsafeBufferPointer(rebasing: arena[Int(node.nameOffset)..<Int(node.nameOffset) + Int(node.nameLength)]))
        }
    }

    func nameEquals(_ index: Int32, _ literal: StaticString) -> Bool {
        let node = nodes[Int(index)]
        guard Int(node.nameLength) == literal.utf8CodeUnitCount else { return false }
        return nameArena.withUnsafeBufferPointer { arena in
            memcmp(arena.baseAddress! + Int(node.nameOffset), literal.utf8Start, literal.utf8CodeUnitCount) == 0
        }
    }

    func nameHasPrefix(_ index: Int32, _ byte: UInt8) -> Bool {
        let node = nodes[Int(index)]
        return node.nameLength > 0 && nameArena[Int(node.nameOffset)] == byte
    }

    public func path(_ index: Int32) -> String {
        var chain: [Int32] = []
        var current = index
        while current >= 0 {
            chain.append(current)
            current = nodes[Int(current)].parent
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chain.count * 16)
        for nodeIndex in chain.reversed() {
            let node = nodes[Int(nodeIndex)]
            if !bytes.isEmpty && bytes.last != UInt8(ascii: "/") { bytes.append(UInt8(ascii: "/")) }
            bytes.append(contentsOf: nameArena[Int(node.nameOffset)..<Int(node.nameOffset) + Int(node.nameLength)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func children(_ index: Int32) -> Range<Int32> {
        let node = nodes[Int(index)]
        return node.childStart..<(node.childStart + node.childCount)
    }

    public func depth(_ index: Int32) -> Int {
        var depth = 0
        var current = nodes[Int(index)].parent
        while current >= 0 {
            depth += 1
            current = nodes[Int(current)].parent
        }
        return depth
    }

    /// The child of `dir` with exactly this name, if any.
    public func child(of dir: Int32, named name: String) -> Int32? {
        let wanted = Array(name.utf8)
        for child in children(dir) {
            let node = nodes[Int(child)]
            guard Int(node.nameLength) == wanted.count else { continue }
            let start = Int(node.nameOffset)
            if nameArena[start..<start + wanted.count].elementsEqual(wanted) { return child }
        }
        return nil
    }

    /// The node for an absolute path, if that path was scanned.
    public func node(atPath path: String) -> Int32? {
        for root in roots {
            let rootPath = self.path(root)
            if path == rootPath { return root }
            guard PathUtil.isSameOrInside(path, rootPath) else { continue }
            var current = root
            let rest = path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1)
            for component in rest.split(separator: "/") {
                guard let next = child(of: current, named: String(component)) else { return nil }
                current = next
            }
            return current
        }
        return nil
    }

    /// Byte-wise name comparison, the order children are stored in.
    func compareNames(_ a: Int32, _ b: Int32) -> Int {
        let na = nodes[Int(a)], nb = nodes[Int(b)]
        return nameArena.withUnsafeBufferPointer { arena in
            let common = min(Int(na.nameLength), Int(nb.nameLength))
            let result = memcmp(arena.baseAddress! + Int(na.nameOffset), arena.baseAddress! + Int(nb.nameOffset), common)
            if result != 0 { return Int(result) }
            return Int(na.nameLength) - Int(nb.nameLength)
        }
    }

    // MARK: - Building

    func appendName(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        let offset = UInt32(nameArena.count)
        nameArena.append(contentsOf: bytes)
        return offset
    }

    func deviceIndex(_ dev: Int32) -> UInt8 {
        if let found = devices.firstIndex(of: dev) { return UInt8(found) }
        guard devices.count < 255 else { return 255 }
        devices.append(dev)
        return UInt8(devices.count - 1)
    }

    func recordError(path: String, code: Int32) {
        errorCount += 1
        if errors.count < FileTree.maxRecordedErrors {
            errors.append(ScanError(path: path, code: code))
        }
    }

    /// Fills in directory totals. Storage that several files share (hard links, APFS clones)
    /// is counted once, on the first file met in a deterministic name-ordered walk.
    func aggregate() {
        var seen = Set<StorageKey>()
        var stack: [Int32] = roots.reversed()
        while let index = stack.popLast() {
            let node = nodes[Int(index)]
            switch node.kind {
            case .dir:
                var child = node.childStart + node.childCount - 1
                while child >= node.childStart {
                    stack.append(child)
                    child -= 1
                }
            case .file:
                if node.flags.contains(.maybeShared) {
                    if !seen.insert(StorageKey(dev: node.dev, cloneID: node.cloneID)).inserted {
                        nodes[Int(index)].flags.insert(.sharedExtra)
                    }
                }
            default:
                break
            }
        }

        // Children always sit at higher indexes than their parent, so one reverse pass is bottom-up.
        var index = nodes.count - 1
        while index >= 0 {
            let node = nodes[index]
            if node.parent >= 0 {
                let parent = Int(node.parent)
                nodes[parent].size += node.size
                if !node.flags.contains(.sharedExtra) { nodes[parent].alloc += node.alloc }
                nodes[parent].fileCount += node.fileCount
                if !node.flags.isDisjoint(with: [.unreadable, .pruned, .dataless, .incomplete, .mount]) {
                    nodes[parent].flags.insert(.incomplete)
                }
            }
            index -= 1
        }
    }
}

/// Identity of a file system object, independent of the path used to reach it.
struct ObjectID: Hashable {
    let dev: Int32
    let inode: UInt64
}

/// Identity of the bytes behind a file: all clones and hard links of a file share one key.
public struct StorageKey: Hashable {
    public let dev: UInt8
    public let cloneID: UInt64

    public init(dev: UInt8, cloneID: UInt64) {
        self.dev = dev
        self.cloneID = cloneID
    }
}
