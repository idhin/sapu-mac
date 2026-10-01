import CryptoKit
import Darwin
import Foundation

/// A SHA-256 value (or a synthetic stand-in of the same width) used as content identity.
public struct ContentDigest: Hashable {
    public let w0: UInt64
    public let w1: UInt64
    public let w2: UInt64
    public let w3: UInt64

    init(_ digest: SHA256.Digest) {
        var words = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        withUnsafeMutableBytes(of: &words) { target in
            digest.withUnsafeBytes { target.copyMemory(from: $0) }
        }
        (w0, w1, w2, w3) = words
    }

    init(w0: UInt64, w1: UInt64, w2: UInt64, w3: UInt64) {
        self.w0 = w0
        self.w1 = w1
        self.w2 = w2
        self.w3 = w3
    }

    /// Identity for a data stream that needs no reading: every file sharing a clone ID has the
    /// same bytes by construction, and no differently-stored file of that size matched it.
    static func stream(_ key: StorageKey, size: Int64) -> ContentDigest {
        ContentDigest(w0: 0x5341_5055_434c_4f4e, w1: UInt64(key.dev), w2: key.cloneID, w3: UInt64(bitPattern: size))
    }

    func update(_ hasher: inout SHA256) {
        var words = (w0, w1, w2, w3)
        withUnsafeBytes(of: &words) { hasher.update(bufferPointer: $0) }
    }

    public var hex: String {
        var words = (w0, w1, w2, w3)
        return withUnsafeBytes(of: &words) { $0.map { String(format: "%02x", $0) }.joined() }
    }
}

enum FileHasher {
    static let bufferSize = 1 << 20
    /// Head and tail sample size for the cheap first pass.
    static let sampleSize = 64 * 1024
    /// Files up to this size are hashed completely straight away.
    static let smallFileLimit: Int64 = 256 * 1024

    private static func openForReading(_ path: String, expectedSize: Int64) -> Int32? {
        // O_NONBLOCK so a file swapped for a FIFO since the scan cannot hang us.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == expectedSize else {
            close(fd)
            return nil
        }
        return fd
    }

    /// SHA-256 of the whole file, or nil if it cannot be read or changed size since the scan.
    /// With `resourceFork`, the fork's bytes are part of the identity as well.
    static func full(path: String, size: Int64, resourceFork: Bool = false, buffer: UnsafeMutableRawPointer, progress: ScanProgress? = nil) -> ContentDigest? {
        guard let fd = openForReading(path, expectedSize: size) else { return nil }
        defer { close(fd) }
        // Keep big one-off reads from evicting everything else in the page cache.
        if size > 32 << 20 { _ = fcntl(fd, F_NOCACHE, 1) }

        var hasher = SHA256()
        guard let total = feed(fd, into: &hasher, buffer: buffer, progress: progress), total == size else { return nil }
        if resourceFork {
            let fork = open(path + "/..namedfork/rsrc", O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fork >= 0 else { return nil }
            defer { close(fork) }
            // The data length goes in first, so "data + fork" cannot be confused with longer data.
            var marker = (UInt64(0x5253_5243_464f_524b), UInt64(bitPattern: size))
            withUnsafeBytes(of: &marker) { hasher.update(bufferPointer: $0) }
            guard feed(fork, into: &hasher, buffer: buffer, progress: nil) != nil else { return nil }
        }
        return ContentDigest(hasher.finalize())
    }

    /// Hashes everything readable from `fd`. Returns the byte count, or nil on a read error.
    private static func feed(_ fd: Int32, into hasher: inout SHA256, buffer: UnsafeMutableRawPointer, progress: ScanProgress?) -> Int64? {
        var total: Int64 = 0
        while true {
            let count = read(fd, buffer, bufferSize)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return total }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            total += Int64(count)
            progress?.advance(Int64(count))
        }
    }

    /// SHA-256 over the first and last `sampleSize` bytes: a cheap filter before `full`.
    static func sample(path: String, size: Int64, buffer: UnsafeMutableRawPointer) -> ContentDigest? {
        guard let fd = openForReading(path, expectedSize: size) else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        for offset in [0, size - Int64(sampleSize)] {
            var done = 0
            while done < sampleSize {
                let count = pread(fd, buffer + done, sampleSize - done, off_t(offset) + off_t(done))
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if count == 0 { return nil }
                done += count
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: sampleSize))
        }
        return ContentDigest(hasher.finalize())
    }

    /// True when both files hold exactly the same bytes.
    static func contentsEqual(_ a: String, _ b: String) -> Bool {
        let fa = open(a, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fa >= 0 else { return false }
        defer { close(fa) }
        let fb = open(b, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fb >= 0 else { return false }
        defer { close(fb) }
        var sa = stat(), sb = stat()
        guard fstat(fa, &sa) == 0, fstat(fb, &sb) == 0,
              sa.st_mode & S_IFMT == S_IFREG, sb.st_mode & S_IFMT == S_IFREG,
              sa.st_size == sb.st_size else { return false }

        let bufferA = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        let bufferB = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer {
            bufferA.deallocate()
            bufferB.deallocate()
        }
        while true {
            guard let countA = readFully(fa, bufferA), let countB = readFully(fb, bufferB), countA == countB else { return false }
            if countA == 0 { return true }
            if memcmp(bufferA, bufferB, countA) != 0 { return false }
        }
    }

    private static func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer) -> Int? {
        var done = 0
        while done < bufferSize {
            let count = read(fd, buffer + done, bufferSize - done)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            done += count
        }
        return done
    }
}

/// Runs `body` for every index in `0..<count` across `threads` threads.
/// `body` receives a per-thread scratch buffer of `FileHasher.bufferSize` bytes.
func parallelForEach(count: Int, threads: Int, _ body: @escaping (_ index: Int, _ buffer: UnsafeMutableRawPointer) -> Void) {
    guard count > 0 else { return }
    let lock = NSLock()
    var next = 0
    let group = DispatchGroup()
    for _ in 0..<max(1, min(threads, count)) {
        group.enter()
        let thread = Thread {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: FileHasher.bufferSize, alignment: 16)
            defer { buffer.deallocate() }
            while true {
                lock.lock()
                let index = next
                next += 1
                lock.unlock()
                if index >= count { break }
                body(index, buffer)
            }
            group.leave()
        }
        thread.start()
    }
    group.wait()
}
