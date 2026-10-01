import Darwin
import Foundation
import Testing
@testable import SapuCore

/// Cases found in review where a wrong verdict or a lost last copy was possible.
@Suite struct RegressionTests {
    /// The Data volume shows every path a second time under this prefix.
    private func alias(_ path: String) -> String? {
        let other = "/System/Volumes/Data" + path
        return PathUtil.sameObject(path, other) ? other : nil
    }

    @Test func oneFolderUnderTwoSpellingsIsNotADuplicate() {
        let box = Sandbox()
        box.write("Album/a.jpg", seed: 1, size: 40_000)
        box.write("Album/sub/b.jpg", seed: 2, size: 40_000)
        guard let other = alias(box.path("Album")) else { return }

        // Resolving the arguments already folds the two spellings into one.
        #expect(PathUtil.normalize(other) == box.path("Album"))
        #expect(PathUtil.dedupeRoots([box.path("Album"), other]) == [box.path("Album")])
        #expect(PathUtil.dedupeRoots([box.path("Album/sub"), other]) == [other])

        // And should both ever reach the scanner, the folder is entered only once.
        for roots in [[box.path("Album"), other], [other, box.path("Album")], [box.path("Album/sub"), other]] {
            let tree = Walker().scan(roots.map { WalkRoot(path: $0) })
            var options = DupeOptions()
            options.minSize = 1
            #expect(DupeFinder(tree: tree, options: options).run().groups.isEmpty, "roots: \(roots)")
        }

        // The same for a single file named twice.
        let file = box.path("Album/a.jpg")
        let tree = Walker().scan([WalkRoot(path: file), WalkRoot(path: alias(file)!)])
        #expect(tree.roots.count == 1)
    }

    @Test func executorTellsCopiesFromAliases() {
        let box = Sandbox()
        box.write("one.bin", seed: 1)
        box.write("two.bin", seed: 1)
        link(box.path("one.bin"), box.path("linked.bin"))
        box.makeDir("folder")

        #expect(!DupeExecutor.isSameObject(box.path("one.bin"), box.path("two.bin")))
        // Two hard-linked names: removing one leaves the file under the other.
        #expect(!DupeExecutor.isSameObject(box.path("one.bin"), box.path("linked.bin")))
        #expect(DupeExecutor.isSameObject(box.path("two.bin"), box.path("two.bin")))
        #expect(DupeExecutor.isSameObject(box.path("folder"), box.path("folder")))
        if let other = alias(box.path("folder")) {
            #expect(DupeExecutor.isSameObject(box.path("folder"), other))
        }
    }

    @Test func aFolderNamedLikeFindersFileIsRealContent() {
        let box = Sandbox()
        box.write("A/data.bin", seed: 1, size: 20_000)
        box.write("A copy/data.bin", seed: 1, size: 20_000)
        box.write("A/.DS_Store/unique-thesis.bin", seed: 2, size: 20_000)

        let (tree, _, result) = box.dupes()
        #expect(result.groups.map(\.kind) == [.file])

        // The change check must see inside such a folder too.
        let folder = tree.child(of: tree.roots[0], named: "A")!
        #expect(tree.changeSinceScan(folder) == nil)
        box.write("A/.DS_Store/added-later.bin", seed: 3, size: 100)
        #expect(tree.changeSinceScan(folder) != nil)
    }

    @Test func copiesInTrashFoldersNeverCount() {
        let box = Sandbox()
        box.write("usb/$RECYCLE.BIN/S-1-5-21/$RABC123.bin", seed: 1, size: 20_000)
        box.write("usb/Work/2024/Client/contract.bin", seed: 1, size: 20_000)
        box.write("vol/.Trashes/501/Album/a.jpg", seed: 2, size: 20_000)
        box.write("vol/Pictures/Old/Album/a.jpg", seed: 2, size: 20_000)
        box.write("share/.Trash-1000/files/notes.pdf", seed: 3, size: 20_000)
        box.write("share/notes.pdf", seed: 3, size: 20_000)

        #expect(box.dupes().result.groups.isEmpty)
        #expect(box.dupes { $0.includeHidden = true }.result.groups.isEmpty)
    }

    @Test func repositoryAboveTheScannedFolderStillHolds() {
        let box = Sandbox()
        box.write("repo/.git/HEAD", text: "ref: refs/heads/main\n")
        box.write("repo/src/assets/logo.bin", seed: 1, size: 20_000)
        box.write("repo/src/assets copy/logo.bin", seed: 1, size: 20_000)

        let group = box.dupes("repo/src").result.groups[0]
        #expect(group.members.allSatisfy { $0.hold == .repository })
        #expect(group.suggested.isEmpty)
    }

    @Test func largeGroupsAreHeldRatherThanGuessedAt() {
        let box = Sandbox()
        // The same file in more folders than are compared pairwise.
        for index in 0...DupeFinder.maxFoldersCompared {
            box.write("p\(index)/lib.bin", seed: 1, size: 3_000)
            box.write("p\(index)/own-\(index).txt", seed: UInt64(1000 + index), size: 50)
        }
        let group = box.dupes().result.groups[0]
        #expect(group.members.count == DupeFinder.maxFoldersCompared + 1)
        #expect(group.members.allSatisfy { $0.hold == .similarFolder })
        #expect(group.suggested.isEmpty)
    }

    @Test func cloneVerdictsAreConfirmedByReadingBeforeRemoval() throws {
        let box = Sandbox()
        box.write("report.bin", seed: 1, size: 300_000)
        box.clone("report.bin", "report copy.bin")
        let (tree, finder, result) = box.dupes()
        let group = result.groups[0]
        #expect(group.members.allSatisfy { !finder.wasRead($0.node) })

        // Change the copy's bytes but put its timestamp back, the way a memory-mapped write can.
        let copy = box.path("report copy.bin")
        var before = stat()
        lstat(copy, &before)
        let handle = FileHandle(forWritingAtPath: copy)!
        try handle.seek(toOffset: 1_000)
        handle.write(Data("edited after the scan".utf8))
        try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        utimensat(AT_FDCWD, copy, &times, 0)
        #expect(tree.changeSinceScan(group.members.first { $0.path == copy }!.node) == nil)

        var outcomes: [DupeOutcome] = []
        let summary = DupeExecutor(tree: tree, finder: finder, groups: result.groups)
            .execute(selections: [0: Set(group.suggested)], action: .delete, dryRun: false) { outcomes.append($0) }
        #expect(summary.done == 0)
        #expect(outcomes.first?.detail?.contains("differs from the copy that stays") == true)
        #expect(box.exists("report copy.bin"))
    }

    @Test func equalInodeNumbersAloneDoNotMergeFiles() {
        let box = Sandbox()
        box.write("a.bin", seed: 1, size: 300_000)
        box.write("a copy.bin", seed: 1, size: 300_000)
        let (_, finder, result) = box.dupes()
        // Independent copies are always read, never matched by ID.
        #expect(result.groups[0].members.allSatisfy { finder.wasRead($0.node) })
        #expect(result.stats.streamMatchedFiles == 0)
    }

    @Test func cloningRefusesALockedSourceAndLeavesNothingBehind() {
        let box = Sandbox()
        box.write("kept.bin", seed: 1, size: 50_000)
        box.write("other.bin", seed: 1, size: 50_000)
        chflags(box.path("kept.bin"), UInt32(UF_IMMUTABLE))
        defer { chflags(box.path("kept.bin"), 0) }

        #expect(throws: ActionFailure.self) {
            try Cloner.replaceWithClone(source: box.path("kept.bin"), target: box.path("other.bin"))
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: box.root))?.sorted() == ["kept.bin", "other.bin"])
    }

    @Test func retargetedSymlinkCountsAsAChange() {
        let box = Sandbox()
        box.write("dir/data.bin", seed: 1)
        symlink("aaaa", box.path("dir/link"))
        let tree = box.scan()
        let dir = tree.child(of: tree.roots[0], named: "dir")!
        #expect(tree.changeSinceScan(dir) == nil)

        unlink(box.path("dir/link"))
        // Keep one extra file alive so the new link cannot reuse the old inode number.
        box.write("spacer", seed: 9)
        symlink("bbbb", box.path("dir/link"))
        #expect(tree.changeSinceScan(dir) != nil)
    }

    @Test func guardsEveryHomeAndItsVaults() {
        let home = PathUtil.home
        for path in ["/Users/someone-else/Documents", "/Users/someone-else/Library", home + "/.ssh", home + "/.ssh/id_ed25519",
                     home + "/Library/Keychains/login.keychain-db", home + "/Library/Mail/V10/x.mbox",
                     home + "/Library/CloudStorage/Dropbox", home + "/Library/Mobile Documents/com~apple~CloudDocs",
                     home + "/Pictures/Photos Library.photoslibrary"] {
            #expect(Guardrails.refusal(for: path) != nil, "\(path) should be protected")
        }
        for path in ["/Users/someone-else/Documents/old copy", home + "/Library/CloudStorage/Dropbox/old copy",
                     home + "/Pictures/Export copy"] {
            #expect(Guardrails.refusal(for: path) == nil, "\(path) should be removable")
        }
    }

    @Test func junkRulesWantMoreThanAFolderName() {
        let box = Sandbox()
        // A user's own folder that happens to be called "build", next to a Gradle file.
        box.write("app/build.gradle", text: "plugins {}")
        box.write("app/build/my-drawings/plan.png", seed: 1, size: 30_000)
        // Real Gradle output.
        box.write("lib/build.gradle", text: "plugins {}")
        box.write("lib/build/intermediates/classes.jar", seed: 2, size: 30_000)
        // A virtual environment is regenerable only up to what was put into it by hand.
        box.write("tool/requirements.txt", text: "requests")
        box.write("tool/venv/pyvenv.cfg", text: "home = /usr/bin")
        box.write("tool/venv/lib/site.py", seed: 3, size: 30_000)

        var options = JunkOptions()
        options.minSize = 1
        options.projectRoots = [box.root]
        options.activeWindow = 0
        let items = JunkFinder(options: options, home: box.root).run().items.filter { $0.targets[0].hasPrefix(box.root) }
        let found = Dictionary(uniqueKeysWithValues: items.map { (String($0.targets[0].dropFirst(box.root.count + 1)), $0.safety) })
        #expect(found == ["lib/build": .safe, "tool/venv": .review])
    }
}
