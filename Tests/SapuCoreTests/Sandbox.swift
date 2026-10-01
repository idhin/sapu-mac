import Darwin
import Foundation
@testable import SapuCore

/// A throwaway directory tree for one test.
final class Sandbox {
    let root: String

    init() {
        let base = PathUtil.realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory()
        root = base + "/sapu-test-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        // Tests may leave read-only folders behind.
        _ = try? Remover.remove(root, mode: .delete)
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    /// Deterministic pseudo-random bytes: equal seeds give equal content.
    static func bytes(seed: UInt64, count: Int) -> Data {
        var state = seed &* 0x9e37_79b9_7f4a_7c15 &+ 1
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for index in 0..<count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        return data
    }

    func makeDir(_ relative: String) {
        try! FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    /// Writes a new, independently stored file (never a clone of another one).
    func write(_ relative: String, seed: UInt64, size: Int = 4096) {
        write(relative, data: Sandbox.bytes(seed: seed, count: size))
    }

    func write(_ relative: String, text: String) {
        write(relative, data: Data(text.utf8))
    }

    func write(_ relative: String, data: Data) {
        let target = path(relative)
        try! FileManager.default.createDirectory(atPath: PathUtil.parent(target), withIntermediateDirectories: true)
        try! data.write(to: URL(fileURLWithPath: target))
    }

    func clone(_ from: String, _ to: String) {
        try! FileManager.default.createDirectory(atPath: PathUtil.parent(path(to)), withIntermediateDirectories: true)
        precondition(clonefile(path(from), path(to), 0) == 0, "clonefile failed: \(String(cString: strerror(errno)))")
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: path(relative))
    }

    func scan(_ relatives: String...) -> FileTree {
        let roots = relatives.isEmpty ? [root] : relatives.map { path($0) }
        return Walker().scan(roots.map { WalkRoot(path: $0) })
    }

    /// Runs the duplicate finder with a 1-byte threshold so small fixtures count.
    func dupes(_ relatives: String..., configure: (inout DupeOptions) -> Void = { _ in }) -> (tree: FileTree, finder: DupeFinder, result: DupeResult) {
        let roots = relatives.isEmpty ? [root] : relatives.map { path($0) }
        let tree = Walker().scan(roots.map { WalkRoot(path: $0) })
        var options = DupeOptions()
        options.minSize = 1
        configure(&options)
        let finder = DupeFinder(tree: tree, options: options)
        return (tree, finder, finder.run())
    }

    /// Paths of a group's members relative to the sandbox, sorted.
    func relative(_ group: DupGroup) -> [String] {
        group.members.map { String($0.path.dropFirst(root.count + 1)) }.sorted()
    }
}
