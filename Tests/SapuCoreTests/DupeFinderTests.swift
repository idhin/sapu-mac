import Darwin
import Foundation
import Testing
@testable import SapuCore

@Suite struct DupeFinderTests {
    /// Writes the same small project under `name`.
    private func makeProject(_ box: Sandbox, _ name: String) {
        box.write("\(name)/readme.md", text: "# Project\n")
        box.write("\(name)/src/main.c", seed: 11, size: 3_000)
        box.write("\(name)/src/util.c", seed: 12, size: 2_000)
        box.write("\(name)/assets/logo.png", seed: 13, size: 50_000)
        box.makeDir("\(name)/empty")
    }

    @Test func findsIdenticalFoldersAsOneGroup() {
        let box = Sandbox()
        makeProject(box, "Project")
        makeProject(box, "Project copy")
        makeProject(box, "Backups/Project")
        box.write("other/unrelated.bin", seed: 99, size: 3_000)

        let (_, _, result) = box.dupes()
        // Only the outermost identical folders are reported, never their contents again.
        #expect(result.groups.count == 1)
        let group = result.groups[0]
        #expect(group.kind == .folder)
        #expect(box.relative(group) == ["Backups/Project", "Project", "Project copy"])
        #expect(group.fileCount == 4)
        #expect(group.size == 10 + 3_000 + 2_000 + 50_000)
        #expect(group.members.allSatisfy { !$0.nested })
        // Keeps the one that does not look like a copy.
        let kept = Set(group.members.indices).subtracting(group.suggested)
        #expect(kept.map { group.members[$0].path } == [box.path("Project")])
        #expect(result.reclaimable > 2 * 55_000)
        #expect(result.shared == 0)
    }

    @Test func reportsLargestIdenticalParts() {
        let box = Sandbox()
        makeProject(box, "A")
        makeProject(box, "B")
        box.write("B/src/extra.c", seed: 50, size: 100) // B diverged a little

        let (_, _, result) = box.dupes()
        let described = result.groups.map { "\($0.kind.rawValue):" + box.relative($0).joined(separator: "|") }.sorted()
        #expect(described == [
            "file:A/readme.md|B/readme.md",
            "file:A/src/main.c|B/src/main.c",
            "file:A/src/util.c|B/src/util.c",
            "folder:A/assets|B/assets",
        ])
    }

    @Test func ignoresFinderMetadataButNotOtherHiddenFiles() {
        let box = Sandbox()
        makeProject(box, "A")
        makeProject(box, "B")
        box.write("B/.DS_Store", text: "finder junk")
        #expect(box.dupes().result.groups.first.map(box.relative) == ["A", "B"])

        // A hidden file that exists in only one copy makes the folders different.
        box.write("B/.env", text: "SECRET=1")
        let groups = box.dupes().result.groups
        #expect(!groups.contains { box.relative($0) == ["A", "B"] })
        #expect(groups.contains { box.relative($0) == ["A/src", "B/src"] })
    }

    @Test func comparesContentNotJustSizes() {
        let box = Sandbox()
        box.write("small-a", seed: 1, size: 5_000)
        box.write("small-b", seed: 2, size: 5_000)
        // Same head and tail, different middle: only a full read can tell these apart.
        var first = Sandbox.bytes(seed: 3, count: 600_000)
        var second = first
        second[300_000] ^= 0xff
        box.write("big-a", data: first)
        box.write("big-b", data: second)
        #expect(box.dupes().result.groups.isEmpty)

        first[10] ^= 1
        box.write("big-a", data: first)
        box.write("big-c", data: second)
        let groups = box.dupes().result.groups
        #expect(groups.count == 1)
        #expect(box.relative(groups[0]) == ["big-b", "big-c"])
    }

    @Test func respectsMinimumSize() {
        let box = Sandbox()
        box.write("a/small", seed: 1, size: 2_000)
        box.write("b/small", seed: 1, size: 2_000)
        box.write("a/large", seed: 2, size: 20_000)
        box.write("c/large", seed: 2, size: 20_000)
        let groups = box.dupes { $0.minSize = 10_000 }.result.groups
        #expect(groups.count == 1)
        #expect(box.relative(groups[0]) == ["a/large", "c/large"])
    }

    @Test func canLimitToFilesOrFolders() {
        let box = Sandbox()
        makeProject(box, "A")
        makeProject(box, "B")
        box.write("loose-1.bin", seed: 70, size: 9_000)
        box.write("loose-2.bin", seed: 70, size: 9_000)

        let foldersOnly = box.dupes { $0.includeFiles = false }.result.groups
        #expect(foldersOnly.map(\.kind) == [.folder])

        let filesOnly = box.dupes { $0.includeFolders = false }.result.groups
        #expect(filesOnly.allSatisfy { $0.kind == .file })
        #expect(filesOnly.count == 5) // 4 project files + the loose pair
    }

    @Test func clonesAreDuplicatesThatFreeNothing() {
        let box = Sandbox()
        box.write("movie.mov", seed: 5, size: 2 << 20)
        box.clone("movie.mov", "movie copy.mov")

        let (_, _, result) = box.dupes()
        #expect(result.groups.count == 1)
        #expect(result.groups[0].suggested.count == 1)
        #expect(result.reclaimable == 0)
        #expect(result.shared == 2 << 20)
        // Identity came from the file system; nothing had to be read.
        #expect(result.stats.hashedFiles == 0)
        #expect(result.stats.streamMatchedFiles == 2)
    }

    @Test func mixesClonesAndRealCopies() {
        let box = Sandbox()
        box.write("a.bin", seed: 5, size: 1 << 20)
        box.clone("a.bin", "a copy.bin")
        box.write("a (1).bin", seed: 5, size: 1 << 20)

        let (_, finder, result) = box.dupes()
        #expect(result.groups.count == 1)
        let group = result.groups[0]
        #expect(box.relative(group) == ["a (1).bin", "a copy.bin", "a.bin"])
        // Two of three go; one of them shares its storage with the survivor or the other.
        #expect(group.suggested.count == 2)
        #expect(group.reclaimable == 1 << 20)
        #expect(group.shared == 1 << 20)
        // Removing everything but the lone real copy frees the cloned megabyte once.
        let onlyRealCopyStays = Set(group.members.indices.filter { !group.members[$0].path.hasSuffix("a (1).bin") })
        #expect(finder.estimateReclaim(group, removing: onlyRealCopyStays).freed == 1 << 20)
    }

    @Test func clonedFoldersAreMeasuredFileByFile() {
        let box = Sandbox()
        box.write("A/one.bin", seed: 1, size: 1 << 20)
        box.write("A/two.bin", seed: 2, size: 1 << 20)
        box.clone("A/one.bin", "A copy/one.bin")       // shares storage
        box.write("A copy/two.bin", seed: 2, size: 1 << 20) // really stored twice

        let (_, _, result) = box.dupes()
        #expect(result.groups.count == 1)
        #expect(result.groups[0].kind == .folder)
        #expect(result.groups[0].reclaimable == 1 << 20)
        #expect(result.groups[0].shared == 1 << 20)
    }

    @Test func toolFoldersAreComparedButNeverTakenApart() {
        let box = Sandbox()
        for project in ["app", "app-backup"] {
            box.write("\(project)/package.json", text: "{}")
            box.write("\(project)/node_modules/lodash/index.js", seed: 30, size: 8_000)
            box.write("\(project)/.git/HEAD", text: "ref: refs/heads/main\n")
        }
        // A different project that happens to share a dependency.
        box.write("other/package.json", text: "{\"name\":\"other\"}")
        box.write("other/node_modules/lodash/index.js", seed: 30, size: 8_000)

        let groups = box.dupes().result.groups
        #expect(groups.count == 1)
        #expect(box.relative(groups[0]) == ["app", "app-backup"])
    }

    @Test func bundlesAreReportedWhole() {
        let box = Sandbox()
        for name in ["Tool.app", "Old/Tool.app"] {
            box.write("\(name)/Contents/MacOS/tool", seed: 40, size: 30_000)
            box.write("\(name)/Contents/Info.plist", text: "<plist/>")
        }
        box.write("Other.app/Contents/MacOS/tool", seed: 40, size: 30_000)
        box.write("Other.app/Contents/Info.plist", text: "<plist version=\"2\"/>")

        let groups = box.dupes().result.groups
        #expect(groups.count == 1)
        #expect(box.relative(groups[0]) == ["Old/Tool.app", "Tool.app"])
    }

    @Test func nestedCopiesOnlyServeAsSurvivors() {
        let box = Sandbox()
        makeProject(box, "A")
        makeProject(box, "A copy")
        // A third copy of just the assets folder, somewhere else.
        box.write("Desktop/assets/logo.png", seed: 13, size: 50_000)

        let groups = box.dupes().result.groups
        #expect(groups.count == 2)
        let outer = groups.first { box.relative($0) == ["A", "A copy"] }!
        #expect(outer.suggested.map { outer.members[$0].path } == [box.path("A copy")])

        let inner = groups.first { $0.members.count == 3 }!
        #expect(box.relative(inner) == ["A copy/assets", "A/assets", "Desktop/assets"])
        let removable = inner.suggested.map { inner.members[$0].path }
        #expect(removable == [box.path("Desktop/assets")])
        #expect(inner.members.filter(\.nested).count == 2)
    }

    @Test func neverSuggestsRemovingPartOfARepository() {
        let box = Sandbox()
        box.write("repo/.git/HEAD", text: "ref: refs/heads/main\n")
        box.write("repo/data/sample.bin", seed: 60, size: 40_000)
        box.write("repo/data/notes.txt", text: "only in the repo")
        box.write("Downloads/sample.bin", seed: 60, size: 40_000)

        let groups = box.dupes().result.groups
        #expect(groups.count == 1)
        let group = groups[0]
        let inRepo = group.members.first { $0.path.hasSuffix("repo/data/sample.bin") }!
        #expect(inRepo.inRepo)
        #expect(group.suggested.map { group.members[$0].path } == [box.path("Downloads/sample.bin")])

        // Two copies inside the same repository: report, but suggest nothing.
        box.write("repo/fixtures/sample.bin", seed: 60, size: 40_000)
        try! FileManager.default.removeItem(atPath: box.path("Downloads"))
        let inside = box.dupes().result.groups
        #expect(inside.count == 1)
        #expect(inside[0].suggested.isEmpty)
    }

    @Test func partsOfSimilarFoldersAreNeverSuggested() {
        let box = Sandbox()
        // Two versions of a site: same big asset folder, different pages.
        for (version, seed) in [("site-v1", UInt64(1)), ("site-v2", UInt64(2))] {
            box.write("\(version)/assets/hero.jpg", seed: 100, size: 60_000)
            box.write("\(version)/index.html", seed: seed, size: 2_000)
            box.write("\(version)/about.html", seed: seed + 10, size: 2_000)
        }
        let groups = box.dupes().result.groups
        #expect(groups.count == 1)
        #expect(box.relative(groups[0]) == ["site-v1/assets", "site-v2/assets"])
        #expect(groups[0].members.allSatisfy { $0.hold == .similarFolder })
        #expect(groups[0].suggested.isEmpty)

        // A loose third copy elsewhere is the one that can go.
        box.write("unsorted/assets/hero.jpg", seed: 100, size: 60_000)
        let withLoose = box.dupes().result.groups
        #expect(withLoose.count == 1)
        #expect(withLoose[0].suggested.map { withLoose[0].members[$0].path } == [box.path("unsorted/assets")])
    }

    @Test func twinsWithUnrelatedNamesInOneFolderAreLeftAlone() {
        let box = Sandbox()
        box.write("locales/en-GB.json", seed: 7, size: 9_000)
        box.write("locales/en-US.json", seed: 7, size: 9_000)
        let group = box.dupes().result.groups[0]
        #expect(group.members.allSatisfy { $0.hold == .sibling })
        #expect(group.suggested.isEmpty)

        // The same pair with a tell-tale name is fair game.
        box.write("docs/guide.pdf", seed: 8, size: 9_000)
        box.write("docs/guide-old.pdf", seed: 8, size: 9_000)
        let guide = box.dupes().result.groups.first { $0.members[0].path.contains("/docs/") }!
        #expect(guide.suggested.map { guide.members[$0].path } == [box.path("docs/guide-old.pdf")])
    }

    @Test func looseItemsInContainersStandOnTheirOwn() {
        let box = Sandbox()
        box.write("Downloads/setup.dmg", seed: 9, size: 9_000)
        box.write("Downloads/notes.txt", seed: 10, size: 500)
        box.write("Downloads/todo.txt", seed: 11, size: 500)
        box.write("Projects/app/setup.dmg", seed: 9, size: 9_000)
        box.write("Projects/app/notes.txt", seed: 12, size: 500)
        box.write("Projects/app/todo.txt", seed: 13, size: 500)

        // The two folders share entry names, so by default both copies are held.
        #expect(box.dupes().result.groups[0].suggested.isEmpty)

        // Declared a container, Downloads gives up its copy.
        let group = box.dupes { $0.containers = [box.path("Downloads")] }.result.groups[0]
        #expect(group.suggested.map { group.members[$0].path } == [box.path("Downloads/setup.dmg")])
    }

    @Test func buildOutputIsLeftToTheJunkCommand() {
        let box = Sandbox()
        for project in ["api", "web"] {
            box.write("\(project)/package.json", text: "{\"name\":\"\(project)\"}")
            box.write("\(project)/node_modules/big/lib.js", seed: 20, size: 50_000)
            box.write("\(project)/Cargo.toml", text: "[package]\nname = \"\(project)\"")
            box.write("\(project)/target/debug/app", seed: 21, size: 70_000)
        }
        let walker = Walker()
        walker.classifier = ScanRules.dupes(home: box.root)
        let tree = walker.scan([WalkRoot(path: box.root)])
        var options = DupeOptions()
        options.minSize = 1
        #expect(DupeFinder(tree: tree, options: options).run().groups.isEmpty)
    }

    @Test func hiddenContentNeedsOptIn() {
        let box = Sandbox()
        box.write(".cache-a/blob", seed: 80, size: 9_000)
        box.write(".cache-b/blob", seed: 80, size: 9_000)
        box.write(".hidden-1", seed: 81, size: 9_000)
        box.write(".hidden-2", seed: 81, size: 9_000)
        #expect(box.dupes().result.groups.isEmpty)
        #expect(box.dupes { $0.includeHidden = true }.result.groups.count == 2)
    }

    @Test func symlinksMustPointToTheSamePlace() {
        let box = Sandbox()
        for name in ["A", "B", "C"] {
            box.write("\(name)/data.bin", seed: 90, size: 9_000)
        }
        symlink("data.bin", box.path("A/link"))
        symlink("data.bin", box.path("B/link"))
        symlink("DATA.BIN", box.path("C/link"))

        let folders = box.dupes().result.groups.filter { $0.kind == .folder }
        #expect(folders.count == 1)
        #expect(box.relative(folders[0]) == ["A", "B"])
    }

    @Test func resourceForksArePartOfTheContent() {
        let box = Sandbox()
        func setFork(_ relative: String, _ text: String) {
            try! Data(text.utf8).write(to: URL(fileURLWithPath: box.path(relative) + "/..namedfork/rsrc"))
        }
        // Classic Mac files keep their content in the fork; the data part is identical or empty.
        box.write("fonts-a/Suitcase", data: Data())
        box.write("fonts-b/Suitcase", data: Data())
        setFork("fonts-a/Suitcase", "glyphs of font ONE")
        setFork("fonts-b/Suitcase", "glyphs of font TWO")
        box.write("fonts-a/readme.txt", seed: 1, size: 5_000)
        box.write("fonts-b/readme.txt", seed: 1, size: 5_000)

        var groups = box.dupes().result.groups
        #expect(groups.count == 1)
        #expect(box.relative(groups[0]) == ["fonts-a/readme.txt", "fonts-b/readme.txt"])

        // With equal forks the folders really are the same.
        setFork("fonts-b/Suitcase", "glyphs of font ONE")
        groups = box.dupes().result.groups
        #expect(groups.map(box.relative) == [["fonts-a", "fonts-b"]])

        // A clone whose fork was changed afterwards is no longer identical, whatever its clone ID says.
        box.write("doc.bin", seed: 2, size: 9_000)
        box.clone("doc.bin", "doc copy.bin")
        #expect(box.dupes("doc.bin", "doc copy.bin").result.groups.count == 1)
        setFork("doc copy.bin", "edited metadata")
        #expect(box.dupes("doc.bin", "doc copy.bin").result.groups.isEmpty)
    }

    @Test func separateRootsCanBeCompared() {
        let box = Sandbox()
        makeProject(box, "left/Project")
        makeProject(box, "right/Project")
        let groups = box.dupes("left/Project", "right/Project").result.groups
        #expect(groups.count == 1)
        #expect(box.relative(groups[0]) == ["left/Project", "right/Project"])
    }
}
