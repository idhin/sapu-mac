import Darwin
import Foundation
import Testing
@testable import SapuCore

@Suite struct WalkerTests {
    @Test func recordsEveryEntryWithSizes() {
        let box = Sandbox()
        box.write("a.bin", seed: 1, size: 10_000)
        box.write("sub/b.bin", seed: 2, size: 5_000)
        box.write("sub/deep/c.txt", text: "hello")
        box.makeDir("empty")
        symlink("a.bin", box.path("link"))

        let tree = box.scan()
        let root = tree.roots[0]
        #expect(tree.path(root) == box.root)
        #expect(tree[root].kind == .dir)
        #expect(tree[root].size == 10_000 + 5_000 + 5 + 5) // files plus the symlink's target length
        #expect(tree[root].fileCount == 3)
        #expect(tree[root].flags.isEmpty)

        let names = tree.children(root).map { tree.name($0) }
        #expect(names == ["a.bin", "empty", "link", "sub"])

        let link = tree.child(of: root, named: "link")!
        #expect(tree[link].kind == .symlink)
        let sub = tree.child(of: root, named: "sub")!
        #expect(tree[sub].size == 5_005)
        let deep = tree.child(of: sub, named: "deep")!
        #expect(tree.path(tree.child(of: deep, named: "c.txt")!) == box.path("sub/deep/c.txt"))
        #expect(tree.depth(deep) == 2)
    }

    @Test func matchesLstatForEveryNode() {
        let box = Sandbox()
        for index in 0..<40 {
            box.write("dir\(index % 5)/file\(index).dat", seed: UInt64(index), size: 100 + index * 37)
        }
        let tree = box.scan()
        var checked = 0
        for index in 0..<Int32(tree.count) where tree[index].kind == .file {
            var info = stat()
            #expect(lstat(tree.path(index), &info) == 0)
            #expect(tree[index].size == Int64(info.st_size))
            #expect(tree[index].inode == UInt64(info.st_ino))
            #expect(tree[index].mtime == Int64(info.st_mtimespec.tv_sec))
            #expect(tree[index].alloc == Int64(info.st_blocks) * 512)
            checked += 1
        }
        #expect(checked == 40)
    }

    @Test func countsSharedStorageOnce() {
        let box = Sandbox()
        box.write("original.bin", seed: 7, size: 1 << 20)
        box.clone("original.bin", "clone.bin")
        link(box.path("original.bin"), box.path("hardlink.bin"))
        box.write("separate.bin", seed: 7, size: 1 << 20)

        let tree = box.scan()
        let root = tree.roots[0]
        let original = tree[tree.child(of: root, named: "original.bin")!]
        let clone = tree[tree.child(of: root, named: "clone.bin")!]
        let hardlink = tree[tree.child(of: root, named: "hardlink.bin")!]
        let separate = tree[tree.child(of: root, named: "separate.bin")!]

        #expect(original.cloneID == clone.cloneID)
        #expect(original.cloneID == hardlink.cloneID)
        #expect(original.cloneID != separate.cloneID)
        // Four names, but only two megabytes are really stored.
        #expect(tree[root].size == 4 << 20)
        #expect(tree[root].alloc == 2 << 20)
    }

    @Test func classifierCanPruneAndTag() {
        let box = Sandbox()
        box.write("keep/a.txt", text: "a")
        box.write("skip/b.txt", text: "b")
        box.write("tagged/c.txt", text: "c")

        let walker = Walker()
        walker.classifier = { listing in
            for index in 0..<listing.count {
                if listing.nameIs(index, "skip") { listing.prune(index) }
                if listing.nameIs(index, "tagged") {
                    listing.setTag(index, 9)
                    listing.setContext(index, 4)
                }
                if listing.nameIs(index, "c.txt") { #expect(listing.context == 4) }
            }
        }
        let tree = walker.scan([WalkRoot(path: box.root)])
        let root = tree.roots[0]
        let skipped = tree.child(of: root, named: "skip")!
        #expect(tree[skipped].flags.contains(.pruned))
        #expect(tree[skipped].childCount == 0)
        #expect(tree[tree.child(of: root, named: "tagged")!].tag == 9)
        #expect(tree[root].flags.contains(.incomplete))
        #expect(tree[root].fileCount == 2)
    }

    @Test func flagsUnreadableFolders() {
        let box = Sandbox()
        box.write("locked/secret.txt", text: "x")
        box.write("open/a.txt", text: "y")
        chmod(box.path("locked"), 0)
        defer { chmod(box.path("locked"), 0o755) }

        let tree = box.scan()
        let root = tree.roots[0]
        #expect(tree[tree.child(of: root, named: "locked")!].flags.contains(.unreadable))
        #expect(tree[root].flags.contains(.incomplete))
        #expect(tree.errorCount == 1)
        #expect(tree.errors.first?.path == box.path("locked"))
    }

    @Test func detectsChangesSinceScan() {
        let box = Sandbox()
        box.write("dir/a.txt", text: "one")
        box.write("dir/sub/b.txt", text: "two")
        let tree = box.scan()
        let dir = tree.child(of: tree.roots[0], named: "dir")!
        #expect(tree.changeSinceScan(dir) == nil)

        // Finder dropping a .DS_Store is not a change.
        box.write("dir/.DS_Store", text: "finder")
        #expect(tree.changeSinceScan(dir) == nil)

        box.write("dir/sub/new.txt", text: "three")
        #expect(tree.changeSinceScan(dir) != nil)
        try! FileManager.default.removeItem(atPath: box.path("dir/sub/new.txt"))
        #expect(tree.changeSinceScan(dir) == nil)

        box.write("dir/sub/b.txt", text: "longer than before")
        #expect(tree.changeSinceScan(dir) != nil)
    }
}
