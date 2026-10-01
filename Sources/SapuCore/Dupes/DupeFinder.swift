import CryptoKit
import Darwin
import Foundation

public struct DupeOptions {
    /// Smallest file, or folder total, worth reporting.
    public var minSize: Int64 = 1_000_000
    public var includeFiles = true
    public var includeFolders = true
    /// Also report hidden files and look inside hidden folders.
    public var includeHidden = false
    /// Folders that merely collect unrelated things. An item sitting directly in one is treated
    /// as standing on its own, so it can be suggested for removal.
    public var containers: Set<String> = {
        let home = PathUtil.home
        return [home, home + "/Downloads", home + "/Desktop", home + "/Documents"]
    }()
    public var threads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

    public init() {}
}

public enum DupKind: String {
    case folder, file
}

public struct DupMember {
    /// Why a copy is never suggested for removal. It can still serve as the copy that stays,
    /// and can still be picked by hand.
    public enum Hold: String {
        /// Sits inside a folder that is itself reported as a duplicate, and is handled through
        /// that folder's group.
        case nested
        /// Part of a git working tree; removing it would leave the repository incomplete.
        case repository
        /// Its folder resembles the folder of its twin (two versions of one project, say).
        /// Removing it would leave that folder incomplete.
        case similarFolder
        /// Lives next to its twin under an unrelated name, which is usually on purpose.
        case sibling
    }

    public let node: Int32
    public let path: String
    public let hold: Hold?
    public let mtime: Int64
    public let depth: Int

    public var nested: Bool { hold == .nested }
    public var inRepo: Bool { hold == .repository }
}

public struct DupGroup {
    public let kind: DupKind
    public let digest: ContentDigest
    /// Logical bytes of one copy.
    public let size: Int64
    /// Files in one copy (1 for a file group).
    public let fileCount: Int
    public var members: [DupMember]
    /// Member indexes the keep policy suggests removing.
    public var suggested: [Int] = []
    /// Bytes that removing `suggested` would actually free.
    public var reclaimable: Int64 = 0
    /// Bytes in `suggested` that free nothing because they are clones or hard links of a kept copy.
    public var shared: Int64 = 0
}

public struct DupeStats {
    public var candidateFiles = 0
    public var sampledFiles = 0
    public var hashedFiles = 0
    public var hashedBytes: Int64 = 0
    /// Files whose identity came from the file system (clone or hard link) without reading them.
    public var streamMatchedFiles = 0
    public var elapsed: TimeInterval = 0
}

public struct DupeResult {
    public var groups: [DupGroup]
    public var stats: DupeStats

    public var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    public var shared: Int64 { groups.reduce(0) { $0 + $1.shared } }
}

/// Finds identical folders and files in a scanned tree.
///
/// A folder is a duplicate when another folder has the same entry names with the same contents,
/// recursively (a Merkle tree over SHA-256). Only the outermost identical folders are reported.
/// To stay fast, a file is read only if something else could still equal it: first by size,
/// then by a head/tail sample, and only then in full.
public final class DupeFinder {
    let tree: FileTree
    let options: DupeOptions
    let progress: ScanProgress?

    private var zone: [UInt8]
    private var digestIndex: [Int32]
    private var digests: [ContentDigest] = []
    private var dupReportable: [Bool]
    /// Files whose identity was taken from the file system (same clone ID as a file that was
    /// read, or as each other) rather than from their own bytes.
    private var unread: [Bool]
    public private(set) var stats = DupeStats()

    /// Above this many distinct folders in one group, folder-by-folder comparison is cut short
    /// and the copies are held rather than guessed about.
    static let maxFoldersCompared = 512

    private enum Zone {
        /// Some ancestor is opaque: never reported, hashed only on behalf of that ancestor.
        static let inOpaque: UInt8 = 1 << 0
        /// Tool-managed or hidden folder: never reported itself either.
        static let selfOpaque: UInt8 = 1 << 1
        /// Bundle such as `.app`: reported as a whole, never taken apart.
        static let bundle: UInt8 = 1 << 2
        static let insideRepo: UInt8 = 1 << 3
        static let hasGit: UInt8 = 1 << 4
        static let hiddenFile: UInt8 = 1 << 5
    }

    public init(tree: FileTree, options: DupeOptions = DupeOptions(), progress: ScanProgress? = nil) {
        self.tree = tree
        self.options = options
        self.progress = progress
        zone = [UInt8](repeating: 0, count: tree.count)
        digestIndex = [Int32](repeating: -1, count: tree.count)
        dupReportable = [Bool](repeating: false, count: tree.count)
        unread = [Bool](repeating: false, count: tree.count)
    }

    /// False for a file that was declared identical on the strength of its clone ID alone.
    /// Such a verdict is confirmed by reading before anything is removed.
    public func wasRead(_ node: Int32) -> Bool {
        !unread[Int(node)]
    }

    public func run(policy: KeepPolicy = KeepPolicy()) -> DupeResult {
        let started = Date()
        classifyZones()
        let hashNeeded = findCandidateFolders()
        hashCandidateFiles(hashNeeded)
        if options.includeFolders { digestFolders(hashNeeded) }
        var groups = buildGroups()

        DupePlanner.suggest(&groups, policy: policy)
        progress?.setPhase("measure", total: Int64(groups.count))
        for index in groups.indices {
            let estimate = estimateReclaim(groups[index], removing: Set(groups[index].suggested))
            groups[index].reclaimable = estimate.freed
            groups[index].shared = estimate.shared
            progress?.advance(1)
        }
        groups.sort { a, b in
            if a.reclaimable != b.reclaimable { return a.reclaimable > b.reclaimable }
            let wasteA = a.size * Int64(a.members.count - 1), wasteB = b.size * Int64(b.members.count - 1)
            if wasteA != wasteB { return wasteA > wasteB }
            return a.members[0].path < b.members[0].path
        }
        stats.elapsed = Date().timeIntervalSince(started)
        return DupeResult(groups: groups, stats: stats)
    }

    // MARK: - Zones

    /// Folders that are never reported and never serve as the copy that stays: version control
    /// internals, dependency folders, and every kind of trash or system bookkeeping.
    private static let toolFolders: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "__pycache__",
        ".Trash", ".Trashes", "$RECYCLE.BIN", "RECYCLER", "System Volume Information", "lost+found",
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
    ]

    private static func isToolFolder(_ name: String) -> Bool {
        // ".Trash-1000" is what Linux desktops leave on shared drives.
        toolFolders.contains(name) || name.hasPrefix(".Trash-")
    }

    static let bundleExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "dext", "xpc", "prefpane", "saver",
        "qlgenerator", "mdimporter", "component", "vst", "vst3", "driver", "docset", "dsym",
        "xcodeproj", "xcworkspace", "xcassets", "xcarchive", "xcdatamodeld", "xcframework", "playground",
        "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "imovielibrary", "aplibrary", "fcpbundle",
        "logicx", "band", "sparsebundle", "rtfd", "pages", "numbers", "key", "scriv", "lrdata",
        "pkg", "mpkg", "pvm", "vmwarevm", "utm", "download", "nib", "storyboardc", "lproj",
    ]

    /// Finder's per-folder settings file. Only the file: a folder of that name is real content.
    private func isIgnorable(_ index: Int32) -> Bool {
        tree.nodes[Int(index)].kind == .file && tree.nameEquals(index, ".DS_Store")
    }

    private func classifyZones() {
        let nodes = tree.nodes
        for index in 0..<nodes.count where nodes[index].parent >= 0 && tree.nameEquals(Int32(index), ".git") {
            zone[Int(nodes[index].parent)] |= Zone.hasGit
        }
        // A scan that starts inside a repository does not see its .git folder; look above the roots.
        for root in tree.roots {
            var folder = PathUtil.parent(tree.path(root))
            while true {
                if access(folder + "/.git", F_OK) == 0 {
                    zone[Int(root)] |= Zone.insideRepo
                    break
                }
                if folder == "/" { break }
                folder = PathUtil.parent(folder)
            }
        }
        // Parents always precede their children, so one forward pass can inherit.
        for index in 0..<nodes.count {
            let node = nodes[index]
            guard node.parent >= 0 else { continue }
            let parentZone = zone[Int(node.parent)]
            var value = zone[index]
            if parentZone & (Zone.inOpaque | Zone.selfOpaque | Zone.bundle) != 0 { value |= Zone.inOpaque }
            if parentZone & (Zone.insideRepo | Zone.hasGit) != 0 { value |= Zone.insideRepo }
            let hidden = tree.nameHasPrefix(Int32(index), UInt8(ascii: "."))
            if node.kind == .dir {
                let name = tree.name(Int32(index))
                if (hidden && !options.includeHidden) || node.tag != 0 || DupeFinder.isToolFolder(name) {
                    value |= Zone.selfOpaque
                } else if let dot = name.lastIndex(of: "."), dot != name.startIndex,
                          DupeFinder.bundleExtensions.contains(name[name.index(after: dot)...].lowercased()) {
                    value |= Zone.bundle
                }
            } else if hidden && !options.includeHidden {
                value |= Zone.hiddenFile
            }
            zone[index] = value
        }
    }

    // MARK: - Structural pre-filter

    @inline(__always)
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 33)) &* 0xff51_afd7_ed55_8ccd
        z = (z ^ (z >> 33)) &* 0xc4ce_b9fe_1a85_ec53
        return z ^ (z >> 33)
    }

    private func nameHash(_ index: Int32) -> UInt64 {
        tree.withNameBytes(index) { bytes in
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
            return DupeFinder.mix(hash)
        }
    }

    /// Marks the folders whose contents must be hashed: those whose shape (entry names, kinds and
    /// file sizes, recursively) also occurs somewhere else. Everything else cannot have a twin.
    private func findCandidateFolders() -> [Bool] {
        let nodes = tree.nodes
        var hashNeeded = [Bool](repeating: false, count: nodes.count)
        guard options.includeFolders else { return hashNeeded }
        progress?.setPhase("structure")

        // 0 means "not comparable": unreadable, incomplete or containing special files.
        var signature = [UInt64](repeating: 0, count: nodes.count)
        let blocked: NodeFlags = [.unreadable, .pruned, .dataless, .mount, .incomplete]
        var folderCount = 0
        var index = nodes.count - 1
        while index >= 0 {
            let node = nodes[index]
            defer { index -= 1 }
            guard node.flags.isDisjoint(with: blocked) else { continue }
            switch node.kind {
            case .file:
                signature[index] = DupeFinder.mix(UInt64(bitPattern: node.size) ^ 0x1f11e) | 1
            case .symlink:
                signature[index] = DupeFinder.mix(UInt64(bitPattern: node.size) ^ 0x2_5911) | 1
            case .other:
                break
            case .dir:
                var hash: UInt64 = 0x9e37_79b9_7f4a_7c15
                var comparable = true
                for child in tree.children(Int32(index)) {
                    if isIgnorable(child) { continue }
                    let childSignature = signature[Int(child)]
                    if childSignature == 0 {
                        comparable = false
                        break
                    }
                    hash = DupeFinder.mix(hash ^ nameHash(child))
                    hash = DupeFinder.mix(hash &+ childSignature)
                }
                if comparable {
                    signature[index] = hash | 1
                    folderCount += 1
                }
            }
        }

        var occurrences = [UInt64: Int32](minimumCapacity: folderCount)
        for index in 0..<nodes.count where nodes[index].kind == .dir && signature[index] != 0 {
            occurrences[signature[index], default: 0] += 1
        }
        for index in 0..<nodes.count where nodes[index].kind == .dir {
            let node = nodes[index]
            let hasTwin = signature[index] != 0 && occurrences[signature[index], default: 0] >= 2
            if node.parent >= 0 && zone[index] & (Zone.inOpaque | Zone.selfOpaque) != 0 {
                // Tool-managed content matters only as part of a reportable ancestor.
                hashNeeded[index] = hashNeeded[Int(node.parent)]
            } else {
                hashNeeded[index] = hasTwin
            }
        }
        return hashNeeded
    }

    // MARK: - File hashing

    private func isReportableFile(_ index: Int) -> Bool {
        let node = tree.nodes[index]
        return options.includeFiles
            && node.kind == .file
            && node.size >= max(options.minSize, 1)
            && zone[index] & (Zone.inOpaque | Zone.hiddenFile) == 0
            && node.flags.isDisjoint(with: [.unreadable, .pruned, .dataless])
    }

    private struct HashJob {
        let node: Int32
        let size: Int64
        /// Range in the sorted candidate list holding every file of this data stream.
        let range: Range<Int>
        /// The file has a resource fork, which must be read along with its data.
        let hasFork: Bool
        var sample: ContentDigest?
        var digest: ContentDigest?
        var needsFull = false
    }

    private func setDigest(_ digest: ContentDigest, for nodes: ArraySlice<Int32>) {
        let slot = Int32(digests.count)
        digests.append(digest)
        for node in nodes { digestIndex[Int(node)] = slot }
    }

    private func hashCandidateFiles(_ hashNeeded: [Bool]) {
        let nodes = tree.nodes
        progress?.setPhase("select")

        var candidates: [Int32] = []
        var emptyFiles: [Int32] = []
        for index in 0..<nodes.count where nodes[index].kind == .file {
            let node = nodes[index]
            guard node.flags.isDisjoint(with: [.unreadable, .pruned, .dataless]) else { continue }
            let forFolder = node.parent >= 0 && hashNeeded[Int(node.parent)] && !isIgnorable(Int32(index))
            guard forFolder || isReportableFile(index) else { continue }
            if node.size == 0 && !node.flags.contains(.resourceFork) {
                emptyFiles.append(Int32(index))
            } else {
                candidates.append(Int32(index))
            }
        }
        if !emptyFiles.isEmpty {
            setDigest(ContentDigest(SHA256.hash(data: Data())), for: emptyFiles[...])
        }
        stats.candidateFiles = candidates.count + emptyFiles.count

        candidates.sort { a, b in
            let na = nodes[Int(a)], nb = nodes[Int(b)]
            if na.size != nb.size { return na.size < nb.size }
            if na.dev != nb.dev { return na.dev < nb.dev }
            if na.cloneID != nb.cloneID { return na.cloneID < nb.cloneID }
            return a < b
        }

        // Split each run of equally sized files into data streams (clones and hard links share one).
        var jobs: [HashJob] = []
        var sizeRuns: [Range<Int>] = []
        var start = 0
        while start < candidates.count {
            let size = nodes[Int(candidates[start])].size
            var end = start + 1
            while end < candidates.count && nodes[Int(candidates[end])].size == size { end += 1 }
            defer { start = end }
            guard end - start >= 2 else { continue }

            let firstJob = jobs.count
            var streamStart = start
            while streamStart < end {
                let first = nodes[Int(candidates[streamStart])]
                // A resource fork is not covered by the clone ID, so such files always stand alone.
                let hasFork = first.flags.contains(.resourceFork)
                // Equal IDs only mean "same data" when the file system says the file is shared at all.
                let mayMerge = !hasFork && first.flags.contains(.maybeShared)
                var streamEnd = streamStart + 1
                while streamEnd < end && mayMerge {
                    let next = nodes[Int(candidates[streamEnd])]
                    if next.dev != first.dev || next.cloneID != first.cloneID
                        || !next.flags.contains(.maybeShared) || next.flags.contains(.resourceFork) { break }
                    streamEnd += 1
                }
                jobs.append(HashJob(node: candidates[streamStart], size: size, range: streamStart..<streamEnd, hasFork: hasFork))
                streamStart = streamEnd
            }
            if jobs.count - firstJob == 1 {
                // One stream only: these files are clones or links of each other, nothing to read.
                let job = jobs.removeLast()
                let node = nodes[Int(job.node)]
                setDigest(.stream(StorageKey(dev: node.dev, cloneID: node.cloneID), size: size), for: candidates[job.range])
                for file in candidates[job.range] { unread[Int(file)] = true }
                stats.streamMatchedFiles += job.range.count
            } else {
                sizeRuns.append(firstJob..<jobs.count)
            }
        }

        // Pass 1: small files in full, larger ones by head/tail sample.
        progress?.setPhase("sample", total: Int64(jobs.count))
        let tree = self.tree
        let progress = self.progress
        jobs.withUnsafeMutableBufferPointer { buffer in
            let base = UnsafeMutablePointer<HashJob>(buffer.baseAddress)
            parallelForEach(count: buffer.count, threads: options.threads) { index, scratch in
                let job = base![index]
                let path = tree.path(job.node)
                if job.size <= FileHasher.smallFileLimit || job.hasFork {
                    base![index].digest = FileHasher.full(path: path, size: job.size, resourceFork: job.hasFork, buffer: scratch)
                } else {
                    base![index].sample = FileHasher.sample(path: path, size: job.size, buffer: scratch)
                }
                progress?.advance(1)
            }
        }
        stats.sampledFiles = jobs.count

        // Pass 2: read completely only where two streams still look alike.
        var fullJobs: [Int] = []
        var fullBytes: Int64 = 0
        for run in sizeRuns where jobs[run.lowerBound].size > FileHasher.smallFileLimit {
            var bySample: [ContentDigest: [Int]] = [:]
            for index in run {
                if let sample = jobs[index].sample { bySample[sample, default: []].append(index) }
            }
            for (_, matching) in bySample where matching.count >= 2 {
                for index in matching {
                    jobs[index].needsFull = true
                    fullJobs.append(index)
                    fullBytes += jobs[index].size
                }
            }
        }
        progress?.setPhase("hash", total: fullBytes)
        jobs.withUnsafeMutableBufferPointer { buffer in
            let base = UnsafeMutablePointer<HashJob>(buffer.baseAddress)
            parallelForEach(count: fullJobs.count, threads: options.threads) { index, scratch in
                let jobIndex = fullJobs[index]
                let job = base![jobIndex]
                base![jobIndex].digest = FileHasher.full(path: tree.path(job.node), size: job.size, buffer: scratch, progress: progress)
            }
        }

        for job in jobs {
            let readInFull = job.size <= FileHasher.smallFileLimit || job.hasFork
            if readInFull || job.needsFull {
                guard let digest = job.digest else { continue }
                setDigest(digest, for: candidates[job.range])
                // Only the first file of the stream was read; its clones ride along.
                for file in candidates[job.range].dropFirst() { unread[Int(file)] = true }
                stats.hashedFiles += 1
                stats.hashedBytes += job.size
            } else if job.range.count >= 2, job.sample != nil {
                // No other stream resembles this one, but its own clones still equal each other.
                let node = nodes[Int(job.node)]
                setDigest(.stream(StorageKey(dev: node.dev, cloneID: node.cloneID), size: job.size), for: candidates[job.range])
                for file in candidates[job.range] { unread[Int(file)] = true }
                stats.streamMatchedFiles += job.range.count
            }
        }
    }

    // MARK: - Folder digests

    private func linkDigest(_ index: Int32) -> ContentDigest? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(tree.path(index), &buffer, buffer.count - 1)
        guard length >= 0 else { return nil }
        var hasher = SHA256()
        hasher.update(data: [UInt8(ascii: "L")])
        buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<length])) }
        return ContentDigest(hasher.finalize())
    }

    private func digestFolders(_ hashNeeded: [Bool]) {
        progress?.setPhase("folders")
        let nodes = tree.nodes
        var index = nodes.count - 1
        while index >= 0 {
            defer { index -= 1 }
            guard nodes[index].kind == .dir, hashNeeded[index] else { continue }
            var hasher = SHA256()
            hasher.update(data: [UInt8(ascii: "D")])
            var complete = true
            for child in tree.children(Int32(index)) {
                if isIgnorable(child) { continue }
                guard let childDigest = entryDigest(child) else {
                    complete = false
                    break
                }
                let childNode = nodes[Int(child)]
                var nameLength = childNode.nameLength
                var kind = childNode.kind.rawValue
                withUnsafeBytes(of: &nameLength) { hasher.update(bufferPointer: $0) }
                withUnsafeBytes(of: &kind) { hasher.update(bufferPointer: $0) }
                tree.withNameBytes(child) { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
                childDigest.update(&hasher)
            }
            if complete {
                setDigest(ContentDigest(hasher.finalize()), for: [Int32(index)][...])
            }
        }
    }

    /// Content identity of one folder entry, or nil if it has none (unique, unreadable or special).
    private func entryDigest(_ index: Int32) -> ContentDigest? {
        switch tree.nodes[Int(index)].kind {
        case .file, .dir:
            let slot = digestIndex[Int(index)]
            return slot >= 0 ? digests[Int(slot)] : nil
        case .symlink:
            return linkDigest(index)
        case .other:
            return nil
        }
    }

    // MARK: - Groups

    private func buildGroups() -> [DupGroup] {
        progress?.setPhase("group")
        let nodes = tree.nodes
        var groups: [DupGroup] = []

        var folderSets: [ContentDigest: [Int32]] = [:]
        if options.includeFolders {
            for index in 0..<nodes.count where nodes[index].kind == .dir && digestIndex[index] >= 0 {
                guard zone[index] & (Zone.inOpaque | Zone.selfOpaque) == 0, nodes[index].size >= max(options.minSize, 1) else { continue }
                folderSets[digests[Int(digestIndex[index])], default: []].append(Int32(index))
            }
            folderSets = folderSets.filter { $0.value.count >= 2 }
            for members in folderSets.values {
                for member in members { dupReportable[Int(member)] = true }
            }
        }

        let containers = Set(options.containers.compactMap { tree.node(atPath: $0) })
        func makeMembers(_ indexes: [Int32]) -> [DupMember] {
            let holds = self.holds(for: indexes, containers: containers)
            return zip(indexes, holds).map { index, hold in
                DupMember(node: index, path: tree.path(index), hold: hold, mtime: nodes[Int(index)].mtime, depth: tree.depth(index))
            }
        }

        for (digest, indexes) in folderSets {
            let members = makeMembers(indexes)
            guard members.contains(where: { !$0.nested }) else { continue }
            let first = nodes[Int(indexes[0])]
            groups.append(DupGroup(kind: .folder, digest: digest, size: first.size, fileCount: Int(first.fileCount), members: members))
        }

        if options.includeFiles {
            var fileSets: [ContentDigest: [Int32]] = [:]
            for index in 0..<nodes.count where digestIndex[index] >= 0 && isReportableFile(index) {
                fileSets[digests[Int(digestIndex[index])], default: []].append(Int32(index))
            }
            for (digest, indexes) in fileSets where indexes.count >= 2 {
                let members = makeMembers(indexes)
                guard members.contains(where: { !$0.nested }) else { continue }
                groups.append(DupGroup(kind: .file, digest: digest, size: nodes[Int(indexes[0])].size, fileCount: 1, members: members))
            }
        }

        for index in groups.indices {
            groups[index].members.sort { $0.path < $1.path }
        }
        return groups
    }

    // MARK: - Holds

    /// Decides, for each copy in a group, whether it stands on its own or belongs to something
    /// that removing it would break.
    private func holds(for indexes: [Int32], containers: Set<Int32>) -> [DupMember.Hold?] {
        let nodes = tree.nodes
        var result = [DupMember.Hold?](repeating: nil, count: indexes.count)
        for (position, index) in indexes.enumerated() {
            let parent = nodes[Int(index)].parent
            if parent >= 0 && dupReportable[Int(parent)] {
                result[position] = .nested
            } else if zone[Int(index)] & Zone.insideRepo != 0 {
                result[position] = .repository
            }
        }

        let names = indexes.map { tree.name($0) }
        var byFolder: [Int32: [Int]] = [:]
        for (position, index) in indexes.enumerated() {
            byFolder[nodes[Int(index)].parent, default: []].append(position)
        }
        let folders = byFolder.keys.filter { $0 >= 0 }.sorted()
        let compared = folders.prefix(DupeFinder.maxFoldersCompared)

        for position in indexes.indices where result[position] == nil {
            let folder = nodes[Int(indexes[position])].parent
            // Scan roots and loose items in Downloads, Desktop and the like stand on their own.
            guard folder >= 0, !containers.contains(folder) else { continue }

            let resembles = compared.contains { other in
                other != folder && foldersResemble(folder, other, ignoring: indexes[position], indexes[byFolder[other]![0]])
            }
            // With more folders than were compared, "no resemblance found" proves nothing: hold.
            if resembles || folders.count > compared.count {
                result[position] = .similarFolder
                continue
            }

            let neighbours = byFolder[folder]!.filter { $0 != position }
            guard !neighbours.isEmpty else { continue }
            let namedLikeCopy = DupePlanner.hasCopyPattern(names[position]) || neighbours.contains { other in
                DupePlanner.hasCopyPattern(names[other]) || DupePlanner.isVariantName(names[position], of: names[other])
                    || DupePlanner.isVariantName(names[other], of: names[position]) || DupePlanner.inSameSeries(names[position], names[other])
            }
            if !namedLikeCopy { result[position] = .sibling }
        }
        return result
    }

    /// True when two folders have enough entry names in common (besides the duplicate itself)
    /// to be versions of the same thing.
    private func foldersResemble(_ a: Int32, _ b: Int32, ignoring skipA: Int32, _ skipB: Int32) -> Bool {
        let left = tree.children(a).filter { $0 != skipA && !isIgnorable($0) }
        let right = tree.children(b).filter { $0 != skipB && !isIgnorable($0) }
        var shared = 0
        var i = 0, j = 0
        while i < left.count && j < right.count {
            let order = tree.compareNames(left[i], right[j])
            if order == 0 {
                shared += 1
                i += 1
                j += 1
            } else if order < 0 {
                i += 1
            } else {
                j += 1
            }
        }
        let smaller = min(left.count, right.count)
        return shared >= 3 || (shared >= 1 && shared * 10 >= smaller * 3)
    }

    // MARK: - Reclaimable space

    /// Bytes that removing the given members would free, and bytes that would free nothing
    /// because a kept copy (or another removed one) shares the same storage.
    public func estimateReclaim(_ group: DupGroup, removing: Set<Int>) -> (freed: Int64, shared: Int64) {
        guard !removing.isEmpty else { return (0, 0) }
        let removed = group.members.indices.map { removing.contains($0) }
        var freed: Int64 = 0
        var shared: Int64 = 0

        func account(_ files: [Int32]) {
            var kept = Set<StorageKey>()
            for (member, file) in files.enumerated() where !removed[member] {
                let node = tree.nodes[Int(file)]
                kept.insert(StorageKey(dev: node.dev, cloneID: node.cloneID))
            }
            var counted = Set<StorageKey>()
            for (member, file) in files.enumerated() where removed[member] {
                let node = tree.nodes[Int(file)]
                let key = StorageKey(dev: node.dev, cloneID: node.cloneID)
                if kept.contains(key) || !counted.insert(key).inserted {
                    shared += node.alloc
                } else {
                    freed += node.alloc
                }
            }
        }

        let roots = group.members.map { $0.node }
        if group.kind == .file {
            account(roots)
            return (freed, shared)
        }

        var aligned = true
        forEachAlignedFile(roots, onMismatch: { aligned = false }, account)
        if !aligned {
            // The copies no longer line up entry by entry; fall back to plain totals.
            freed = 0
            shared = 0
            for (member, root) in roots.enumerated() where removed[member] { freed += tree.nodes[Int(root)].alloc }
        }
        return (freed, shared)
    }

    /// Walks identical folders in lockstep and calls `body` with the corresponding file of every copy.
    func forEachAlignedFile(_ roots: [Int32], onMismatch: () -> Void, _ body: ([Int32]) -> Void) {
        var stack: [[Int32]] = [roots]
        while let dirs = stack.popLast() {
            let lists = dirs.map { dir in tree.children(dir).filter { !isIgnorable($0) } }
            guard let first = lists.first, lists.allSatisfy({ $0.count == first.count }) else {
                onMismatch()
                return
            }
            for position in 0..<first.count {
                let entries = lists.map { $0[position] }
                let kind = tree.nodes[Int(entries[0])].kind
                for entry in entries.dropFirst() {
                    if tree.nodes[Int(entry)].kind != kind || tree.compareNames(entry, entries[0]) != 0 {
                        onMismatch()
                        return
                    }
                }
                switch kind {
                case .dir: stack.append(entries)
                case .file: body(entries)
                default: break
                }
            }
        }
    }
}
