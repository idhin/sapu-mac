import Darwin
import Foundation

/// Thread-safe counters a UI can poll while a scan or hash pass is running.
public final class ScanProgress {
    public struct Snapshot {
        public var phase: String
        public var items: Int
        public var path: String
        public var done: Int64
        public var total: Int64
    }

    private let lock = NSLock()
    private var state = Snapshot(phase: "", items: 0, path: "", done: 0, total: 0)

    public init() {}

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func setPhase(_ phase: String, total: Int64 = 0) {
        lock.lock()
        state.phase = phase
        state.done = 0
        state.total = total
        lock.unlock()
    }

    func addItems(_ count: Int, path: String) {
        lock.lock()
        state.items += count
        state.path = path
        lock.unlock()
    }

    func advance(_ amount: Int64) {
        lock.lock()
        state.done += amount
        lock.unlock()
    }
}

public struct WalkRoot {
    public let path: String
    /// Starting value of the context byte that classifiers can hand down the tree.
    public let context: UInt8

    public init(path: String, context: UInt8 = 0) {
        self.path = path
        self.context = context
    }
}

struct ParsedEntry {
    var nameOffset: Int32 = 0
    var nameLength: Int32 = 0
    var kind: NodeKind = .other
    var stFlags: UInt32 = 0
    var dev: Int32 = 0
    var mtime: Int64 = 0
    var mtimeNanos: UInt32 = 0
    var inode: UInt64 = 0
    var nlink: UInt32 = 1
    var alloc: Int64 = 0
    var size: Int64 = 0
    var cloneID: UInt64 = 0
    var cloneRefs: UInt32 = 1
    var hasResourceFork = false
    var sizeKnown = false
    var failed = false
    var prune = false
    var context: UInt8 = 0
    var tag: UInt8 = 0
}

/// The entries of one directory, handed to a classifier before the walker descends.
/// Only valid during the classifier call.
public final class DirListing {
    public internal(set) var path = ""
    /// Context byte inherited from the parent directory.
    public internal(set) var context: UInt8 = 0
    /// 0 for a scan root.
    public internal(set) var depth = 0
    var entries: [ParsedEntry] = []
    var arena: [UInt8] = []
    /// An entry could not be represented, so the listing does not show everything that is there.
    var incomplete = false

    public var count: Int { entries.count }

    public func kind(_ index: Int) -> NodeKind { entries[index].kind }

    public func name(_ index: Int) -> String {
        let entry = entries[index]
        let start = Int(entry.nameOffset)
        return String(decoding: arena[start..<start + Int(entry.nameLength)], as: UTF8.self)
    }

    public func nameIs(_ index: Int, _ literal: StaticString) -> Bool {
        let entry = entries[index]
        guard Int(entry.nameLength) == literal.utf8CodeUnitCount else { return false }
        return arena.withUnsafeBufferPointer {
            memcmp($0.baseAddress! + Int(entry.nameOffset), literal.utf8Start, literal.utf8CodeUnitCount) == 0
        }
    }

    public func isHidden(_ index: Int) -> Bool {
        let entry = entries[index]
        return entry.nameLength > 0 && arena[Int(entry.nameOffset)] == UInt8(ascii: ".")
    }

    /// True if the directory has an entry with exactly this name.
    public func contains(_ name: String) -> Bool {
        indexOf(name) != nil
    }

    public func indexOf(_ name: String) -> Int? {
        let wanted = Array(name.utf8)
        for (index, entry) in entries.enumerated() where Int(entry.nameLength) == wanted.count {
            let start = Int(entry.nameOffset)
            if arena[start..<start + wanted.count].elementsEqual(wanted) { return index }
        }
        return nil
    }

    /// True if any entry name ends with `suffix` (for markers such as `.xcodeproj`).
    public func containsSuffix(_ suffix: String) -> Bool {
        let wanted = Array(suffix.utf8)
        for entry in entries where Int(entry.nameLength) > wanted.count {
            let end = Int(entry.nameOffset) + Int(entry.nameLength)
            if arena[(end - wanted.count)..<end].elementsEqual(wanted) { return true }
        }
        return false
    }

    /// Do not descend into (or account for) this entry. Its parent becomes "incomplete".
    public func prune(_ index: Int) { entries[index].prune = true }

    /// Context byte the entry's own listing will receive. Defaults to this directory's context.
    public func setContext(_ index: Int, _ context: UInt8) { entries[index].context = context }

    /// Stored on the resulting node as `Node.tag`.
    public func setTag(_ index: Int, _ tag: UInt8) { entries[index].tag = tag }

    func reset(path: String, context: UInt8, depth: Int) {
        self.path = path
        self.context = context
        self.depth = depth
        incomplete = false
        entries.removeAll(keepingCapacity: true)
        arena.removeAll(keepingCapacity: true)
    }

    func sortByName() {
        arena.withUnsafeBufferPointer { names in
            guard let base = names.baseAddress else { return }
            entries.sort { a, b in
                let common = Int(min(a.nameLength, b.nameLength))
                let result = memcmp(base + Int(a.nameOffset), base + Int(b.nameOffset), common)
                return result != 0 ? result < 0 : a.nameLength < b.nameLength
            }
        }
    }
}

private struct DirTask {
    let node: Int32
    let path: String
    let dev: Int32
    let devIndex: UInt8
    let context: UInt8
    let depth: Int32
}

private final class WorkQueue<Item> {
    private let condition = NSCondition()
    private var items: [Item] = []
    private var active = 0

    func push(_ new: [Item]) {
        guard !new.isEmpty else { return }
        condition.lock()
        items.append(contentsOf: new)
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until work is available. Returns nil once the queue is drained and nobody is working.
    func pop() -> Item? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let item = items.popLast() {
                active += 1
                return item
            }
            if active == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    func finished() {
        condition.lock()
        active -= 1
        if active == 0 && items.isEmpty { condition.broadcast() }
        condition.unlock()
    }
}

/// Walks directory trees on several threads using `getattrlistbulk`, never following symlinks.
public final class Walker {
    /// Called once per directory, concurrently from several threads. Must be thread-safe.
    public typealias Classifier = (DirListing) -> Void

    public var threads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
    /// Descend into other mounted volumes found below the roots.
    public var crossDevices = false
    public var classifier: Classifier?
    public var progress: ScanProgress?

    public init() {}

    public func scan(_ roots: [WalkRoot]) -> FileTree {
        let started = Date()
        let tree = FileTree()
        var allowedDevices = Set<Int32>()
        var tasks: [DirTask] = []
        var rootFiles = Set<ObjectID>()
        let systemDevice = Walker.device(of: "/")

        for root in roots {
            var info = stat()
            guard lstat(root.path, &info) == 0 else {
                tree.recordError(path: root.path, code: errno)
                continue
            }
            let devIndex = tree.deviceIndex(info.st_dev)
            allowedDevices.insert(info.st_dev)
            // "/" is the sealed system volume; user data sits on the Data volume behind firmlinks.
            if info.st_dev == systemDevice, let dataDevice = Walker.device(of: "/System/Volumes/Data") {
                allowedDevices.insert(dataDevice)
            }
            let kind = Walker.kind(mode: info.st_mode)
            let identity = ObjectID(dev: info.st_dev, inode: UInt64(info.st_ino))
            // The same file named twice through different paths is one file, not two copies.
            if kind == .file && info.st_nlink < 2 && !rootFiles.insert(identity).inserted { continue }
            let nameBytes = Array(root.path.utf8)
            let nameOffset = nameBytes.withUnsafeBufferPointer { tree.appendName($0) }
            let index = Int32(tree.nodes.count)
            // A root that is a single file gets the details a directory listing would have given it.
            var flags: NodeFlags = []
            var cloneID = UInt64(info.st_ino)
            if kind == .dir && !tree.entered.insert(identity).inserted {
                flags.insert(.pruned)
            }
            if kind == .file {
                let clone = Walker.cloneInfo(of: root.path)
                cloneID = clone?.id ?? cloneID
                if info.st_nlink > 1 || (clone?.references ?? 1) > 1 { flags.insert(.maybeShared) }
                if getxattr(root.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW) > 0 { flags.insert(.resourceFork) }
                if info.st_flags & Attr.datalessFlag != 0 { flags.insert(.dataless) }
            }
            tree.nodes.append(Node(
                parent: -1,
                nameOffset: nameOffset,
                childStart: 0,
                childCount: 0,
                size: kind == .dir ? 0 : Int64(info.st_size),
                alloc: kind == .dir ? 0 : Int64(info.st_blocks) * 512,
                mtime: Int64(info.st_mtimespec.tv_sec),
                inode: UInt64(info.st_ino),
                cloneID: cloneID,
                fileCount: kind == .file ? 1 : 0,
                mtimeNanos: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec),
                nameLength: UInt16(nameBytes.count),
                kind: kind,
                flags: flags,
                dev: devIndex,
                tag: 0
            ))
            tree.roots.append(index)
            if kind == .dir && flags.isEmpty {
                tasks.append(DirTask(node: index, path: root.path, dev: info.st_dev, devIndex: devIndex, context: root.context, depth: 0))
            }
        }

        let queue = WorkQueue<DirTask>()
        queue.push(tasks)
        let lock = NSLock()
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            let thread = Thread {
                let worker = WalkWorker(walker: self, tree: tree, lock: lock, queue: queue, allowedDevices: allowedDevices)
                worker.run()
                group.leave()
            }
            thread.start()
        }
        group.wait()

        tree.aggregate()
        tree.elapsed = Date().timeIntervalSince(started)
        return tree
    }

    /// Clone ID and clone count of one file, as `getattrlistbulk` reports them for directory entries.
    static func cloneInfo(of path: String) -> (id: UInt64, references: UInt32)? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = Attr.cmnReturnedAttrs
        attributes.forkattr = Attr.extCloneID | Attr.extCloneRefCount
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &attributes, &buffer, buffer.count, UInt32(Attr.optExtended) | 0x1) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            // Length (4 bytes), then the returned-attributes set (5 x 4 bytes), then the values.
            let returnedFork = raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            guard returnedFork & Attr.extCloneID != 0 else { return nil }
            let id = raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            let references = returnedFork & Attr.extCloneRefCount != 0 ? raw.loadUnaligned(fromByteOffset: 32, as: UInt32.self) : 1
            return (id, references)
        }
    }

    static func device(of path: String) -> Int32? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_dev : nil
    }

    static func kind(mode: mode_t) -> NodeKind {
        switch mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .dir
        case S_IFLNK: return .symlink
        default: return .other
        }
    }
}

// Attribute bits from <sys/attr.h>, spelled out because Swift imports them with mixed signedness.
private enum Attr {
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnModTime: UInt32 = 0x0000_0400
    static let cmnFlags: UInt32 = 0x0004_0000
    static let cmnFileID: UInt32 = 0x0200_0000
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileAllocSize: UInt32 = 0x0000_0004
    static let fileDataLength: UInt32 = 0x0000_0200
    static let fileResourceLength: UInt32 = 0x0000_1000
    static let extCloneID: UInt32 = 0x0000_0100
    static let extCloneRefCount: UInt32 = 0x0000_1000
    static let optExtended: UInt64 = 0x0000_0020
    static let datalessFlag: UInt32 = 0x4000_0000
}

private enum ReadOutcome {
    case ok
    case unsupported
    case failed(Int32)
}

private final class WalkWorker {
    static let bufferSize = 256 * 1024

    let walker: Walker
    let tree: FileTree
    let lock: NSLock
    let queue: WorkQueue<DirTask>
    let allowedDevices: Set<Int32>
    let buffer: UnsafeMutableRawPointer
    let listing = DirListing()
    var attributes = attrlist()

    init(walker: Walker, tree: FileTree, lock: NSLock, queue: WorkQueue<DirTask>, allowedDevices: Set<Int32>) {
        self.walker = walker
        self.tree = tree
        self.lock = lock
        self.queue = queue
        self.allowedDevices = allowedDevices
        buffer = UnsafeMutableRawPointer.allocate(byteCount: WalkWorker.bufferSize, alignment: 8)
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = Attr.cmnReturnedAttrs | Attr.cmnName | Attr.cmnDevID | Attr.cmnObjType
            | Attr.cmnModTime | Attr.cmnFlags | Attr.cmnFileID | Attr.cmnError
        attributes.fileattr = Attr.fileLinkCount | Attr.fileAllocSize | Attr.fileDataLength | Attr.fileResourceLength
        attributes.forkattr = Attr.extCloneID | Attr.extCloneRefCount
    }

    deinit {
        buffer.deallocate()
    }

    func run() {
        while let task = queue.pop() {
            process(task)
            queue.finished()
        }
    }

    private func fail(_ task: DirTask, _ code: Int32) {
        lock.lock()
        tree.nodes[Int(task.node)].flags.insert(.unreadable)
        tree.recordError(path: task.path, code: code)
        lock.unlock()
    }

    private func process(_ task: DirTask) {
        let fd = open(task.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            fail(task, errno)
            return
        }
        defer { close(fd) }

        listing.reset(path: task.path, context: task.context, depth: Int(task.depth))
        var outcome = readBulk(fd, task)
        if case .unsupported = outcome {
            listing.reset(path: task.path, context: task.context, depth: Int(task.depth))
            outcome = readPortable(fd, task)
        }
        if case .failed(let code) = outcome {
            fail(task, code)
            return
        }
        guard listing.count > 0 else {
            if listing.incomplete {
                lock.lock()
                tree.nodes[Int(task.node)].flags.insert(.incomplete)
                lock.unlock()
            }
            return
        }

        pruneSystemMounts(task)
        walker.classifier?(listing)
        listing.sortByName()

        var descend: [Int] = []
        lock.lock()
        let start = Int32(tree.nodes.count)
        for (offset, entry) in listing.entries.enumerated() {
            var flags: NodeFlags = []
            var devIndex = task.devIndex
            var enter = false
            if entry.failed { flags.insert(.unreadable) }
            if entry.prune { flags.insert(.pruned) }
            if entry.stFlags & Attr.datalessFlag != 0 { flags.insert(.dataless) }
            switch entry.kind {
            case .dir:
                if entry.dev != task.dev {
                    devIndex = tree.deviceIndex(entry.dev)
                    if !(walker.crossDevices || allowedDevices.contains(entry.dev)) { flags.insert(.mount) }
                }
                enter = flags.isEmpty
                // Reached before under another path: an alias of something already scanned.
                if enter && entry.inode != 0 && !tree.entered.insert(ObjectID(dev: entry.dev, inode: entry.inode)).inserted {
                    flags.insert(.pruned)
                    enter = false
                }
            case .file:
                if entry.nlink > 1 || entry.cloneRefs > 1 { flags.insert(.maybeShared) }
                if entry.hasResourceFork { flags.insert(.resourceFork) }
            default:
                break
            }
            let nameOffset = listing.arena.withUnsafeBufferPointer { names in
                tree.appendName(UnsafeBufferPointer(rebasing: names[Int(entry.nameOffset)..<Int(entry.nameOffset + entry.nameLength)]))
            }
            let isDir = entry.kind == .dir
            tree.nodes.append(Node(
                parent: task.node,
                nameOffset: nameOffset,
                childStart: 0,
                childCount: 0,
                size: isDir ? 0 : entry.size,
                alloc: isDir ? 0 : entry.alloc,
                mtime: entry.mtime,
                inode: entry.inode,
                cloneID: entry.cloneID != 0 ? entry.cloneID : entry.inode,
                fileCount: entry.kind == .file ? 1 : 0,
                mtimeNanos: entry.mtimeNanos,
                nameLength: UInt16(truncatingIfNeeded: entry.nameLength),
                kind: entry.kind,
                flags: flags,
                dev: devIndex,
                tag: entry.tag
            ))
            if enter { descend.append(offset) }
        }
        tree.nodes[Int(task.node)].childStart = start
        tree.nodes[Int(task.node)].childCount = Int32(listing.count)
        if listing.incomplete { tree.nodes[Int(task.node)].flags.insert(.incomplete) }
        lock.unlock()

        walker.progress?.addItems(listing.count, path: task.path)

        guard !descend.isEmpty else { return }
        let prefix = task.path == "/" ? "/" : task.path + "/"
        var subtasks: [DirTask] = []
        subtasks.reserveCapacity(descend.count)
        for offset in descend {
            let entry = listing.entries[offset]
            subtasks.append(DirTask(
                node: start + Int32(offset),
                path: prefix + listing.name(offset),
                dev: entry.dev,
                devIndex: entry.dev == task.dev ? task.devIndex : lookupDevice(entry.dev),
                context: entry.context,
                depth: task.depth + 1
            ))
        }
        queue.push(subtasks)
    }

    private func lookupDevice(_ dev: Int32) -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        return tree.deviceIndex(dev)
    }

    /// When scanning from the top of the disk, skip the places that mirror or mount other volumes.
    private func pruneSystemMounts(_ task: DirTask) {
        let names: [StaticString]
        switch task.path {
        case "/": names = ["Volumes", "dev", ".vol", "net", "home"]
        case "/System": names = ["Volumes"]
        default: return
        }
        for index in 0..<listing.count where names.contains(where: { listing.nameIs(index, $0) }) {
            listing.prune(index)
        }
    }

    private func readBulk(_ fd: Int32, _ task: DirTask) -> ReadOutcome {
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, WalkWorker.bufferSize, Attr.optExtended)
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if listing.count == 0 && (code == ENOTSUP || code == EINVAL || code == ENOTTY) { return .unsupported }
                return .failed(code)
            }
            if count == 0 { return .ok }

            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                defer { cursor += length }
                var field = cursor + 4
                let returnedCommon = field.loadUnaligned(as: UInt32.self)
                let returnedFile = (field + 12).loadUnaligned(as: UInt32.self)
                let returnedFork = (field + 16).loadUnaligned(as: UInt32.self)
                field += 20

                var entry = ParsedEntry()
                entry.context = task.context
                entry.dev = task.dev
                if returnedCommon & Attr.cmnError != 0 {
                    entry.failed = field.loadUnaligned(as: UInt32.self) != 0
                    field += 4
                }
                guard returnedCommon & Attr.cmnName != 0 else {
                    listing.incomplete = true
                    continue
                }
                let nameOffset = Int(field.loadUnaligned(as: Int32.self))
                let nameLength = Int((field + 4).loadUnaligned(as: UInt32.self))
                let name = UnsafeBufferPointer(start: (field + nameOffset).assumingMemoryBound(to: UInt8.self), count: max(0, nameLength - 1))
                entry.nameOffset = Int32(listing.arena.count)
                entry.nameLength = Int32(name.count)
                listing.arena.append(contentsOf: name)
                field += 8

                if returnedCommon & Attr.cmnDevID != 0 {
                    entry.dev = field.loadUnaligned(as: Int32.self)
                    field += 4
                }
                if returnedCommon & Attr.cmnObjType != 0 {
                    switch field.loadUnaligned(as: UInt32.self) {
                    case 1: entry.kind = .file
                    case 2: entry.kind = .dir
                    case 5: entry.kind = .symlink
                    default: entry.kind = .other
                    }
                    field += 4
                }
                if returnedCommon & Attr.cmnModTime != 0 {
                    entry.mtime = field.loadUnaligned(as: Int64.self)
                    entry.mtimeNanos = UInt32(truncatingIfNeeded: (field + 8).loadUnaligned(as: Int64.self))
                    field += 16
                }
                if returnedCommon & Attr.cmnFlags != 0 {
                    entry.stFlags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returnedCommon & Attr.cmnFileID != 0 {
                    entry.inode = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                if returnedFile & Attr.fileLinkCount != 0 {
                    entry.nlink = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returnedFile & Attr.fileAllocSize != 0 {
                    entry.alloc = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                if returnedFile & Attr.fileDataLength != 0 {
                    entry.size = field.loadUnaligned(as: Int64.self)
                    entry.sizeKnown = true
                    field += 8
                }
                if returnedFile & Attr.fileResourceLength != 0 {
                    entry.hasResourceFork = field.loadUnaligned(as: Int64.self) > 0
                    field += 8
                }
                if returnedFork & Attr.extCloneID != 0 {
                    entry.cloneID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                if returnedFork & Attr.extCloneRefCount != 0 {
                    entry.cloneRefs = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                // A file whose length was not reported cannot be compared with anything.
                if entry.kind == .file && !entry.sizeKnown { entry.failed = true }
                listing.entries.append(entry)
            }
        }
    }

    /// For file systems where `getattrlistbulk` is unavailable.
    private func readPortable(_ fd: Int32, _ task: DirTask) -> ReadOutcome {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { return .failed(errno) }
        guard let dir = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            return .failed(code)
        }
        defer { closedir(dir) }
        rewinddir(dir)

        while let pointer = readdir(dir) {
            let nameLength = Int(pointer.pointee.d_namlen)
            let appended: Bool = withUnsafeBytes(of: &pointer.pointee.d_name) { raw in
                let name = UnsafeBufferPointer(start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: nameLength)
                if nameLength == 1 && name[0] == UInt8(ascii: ".") { return false }
                if nameLength == 2 && name[0] == UInt8(ascii: ".") && name[1] == UInt8(ascii: ".") { return false }

                var entry = ParsedEntry()
                entry.context = task.context
                entry.nameOffset = Int32(listing.arena.count)
                entry.nameLength = Int32(nameLength)
                listing.arena.append(contentsOf: name)

                var info = stat()
                if fstatat(fd, raw.baseAddress!.assumingMemoryBound(to: CChar.self), &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    entry.kind = Walker.kind(mode: info.st_mode)
                    entry.stFlags = info.st_flags
                    entry.dev = info.st_dev
                    entry.mtime = Int64(info.st_mtimespec.tv_sec)
                    entry.mtimeNanos = UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec)
                    entry.inode = UInt64(info.st_ino)
                    entry.nlink = UInt32(info.st_nlink)
                    entry.alloc = Int64(info.st_blocks) * 512
                    entry.size = Int64(info.st_size)
                    if entry.kind == .file {
                        let path = task.path + "/" + String(decoding: name, as: UTF8.self)
                        entry.hasResourceFork = getxattr(path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW) > 0
                    }
                } else {
                    entry.dev = task.dev
                    entry.failed = true
                }
                listing.entries.append(entry)
                return true
            }
            _ = appended
        }
        return .ok
    }
}
