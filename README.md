# sapu mac

**Sweep your Mac's disk clean, without losing anything.**

**sapu mac** is a fast command-line disk cleaner for macOS; the command is `sapu`, Indonesian for *broom*. It finds three kinds of waste:

| Command | Finds |
| --- | --- |
| `sapu junk` | Caches, build output and installed dependencies that tools recreate on demand |
| `sapu dupes` | Identical **folders** and files, wherever they are |
| `sapu big` | What is actually taking the space |

It only reports until you tell it to act, and it is built so that acting cannot cost you data.

[Bahasa Indonesia](README.id.md)

## Why another cleaner

- **It finds duplicate folders, not just duplicate files.** Two copies of a 40,000-file project show up as one line, not 40,000.
- **It knows about APFS clones.** When you duplicate something in Finder, macOS stores the data once. Most tools report those copies as wasted space; `sapu` tells you they free nothing, and counts shared data once in every total.
- **It can deduplicate without deleting.** `--clone` keeps every path where it is and makes identical files share storage.
- **It is careful by design.** See [Safety](#safety).
- **It is fast.** A home folder with 2.8 million items is scanned and compared in about 20 seconds on an M-series Mac.
- **No dependencies, no network, no telemetry.** One small native binary.

## Install

Download the latest universal binary (Apple silicon and Intel, macOS 12 or later):

```sh
curl -fsSL https://raw.githubusercontent.com/idhin/sapu-mac/main/install.sh | sh
```

Or build from source (needs Xcode or the Command Line Tools):

```sh
git clone https://github.com/idhin/sapu-mac.git
cd sapu-mac
make install          # installs to /usr/local/bin; use PREFIX=~/.local for another place
```

## Quick start

```sh
sapu              # how full is the disk?
sapu junk         # what can be regenerated? (usually the quickest win)
sapu junk -i      # tick what should go, then choose Trash or delete
sapu dupes ~/Documents ~/Downloads
sapu big          # where did the space go?
```

Every command accepts `--help`, and `--json` for scripting.

## `sapu junk`

```
Junk: caches, build output and other regenerable data
Scanned 2,334,003 items in 7.2s

Project build artifacts  [projects]                                                  32.6 GB
 ●   3.25 GB  ~/Projects/shop/.next                      JavaScript build cache · 12 days ago
 ◐   2.10 GB  ~/Projects/pos/mobile/build                     Flutter build output · just now
              Project in active use; it would need: flutter pub get && flutter build
 ●   1.18 GB  ~/Projects/indexer/target                       Rust build output · 15 days ago
              … 108 more findings (26.1 GB). List them with --all.

Package manager caches  [packages]                                                   9.20 GB
 ●   4.01 GB  Gradle caches                                                       ~/.gradle/…
 ●   2.07 GB  Go module cache                                                    ~/go/pkg/mod
 ◐   1.53 GB  Hugging Face models                                        ~/.cache/huggingface
              Downloaded models and datasets

Large app data  [large]                                                              16.9 GB
 ○   16.9 GB  Docker disk image               ~/Library/Containers/com.docker.docker/Data/vms
              Reclaim with: docker system prune -a --volumes

● safe to remove: 45.0 GB   ◐ worth a review: 12.8 GB   ○ reported only: 16.9 GB
```

Each finding carries one of three marks:

| Mark | Meaning | Removed by `--delete` |
| --- | --- | --- |
| ● safe | Rebuilt or re-downloaded automatically | Yes |
| ◐ review | Regenerable, but at a cost or not provably so: a project you touched this week, dependencies without a lockfile, Python virtual environments, simulator data, downloaded models, the Trash | Only with `--review`, or by ticking it in `-i` |
| ○ info | Reported with the proper way to reclaim it (for example Docker's disk image) | Never |

What it looks for:

- **Project build artifacts**, found by walking your folders: `node_modules`, `.next`, `target` (Rust, Maven), `.build` (SwiftPM), `build` (Gradle, Flutter, Xcode, CMake), `Pods`, `.venv`, `vendor` (Composer), `bin`/`obj` (.NET), `.terraform`, Unity, Unreal and Godot caches, and more. A folder only counts when the evidence for what it is sits next to it or inside it: `target` needs a `Cargo.toml`, `node_modules` needs a `package.json`, and a folder merely called `build` must also contain what its build tool produces.
- **Developer tools**: Xcode DerivedData, device support, archives, simulators.
- **Package manager caches**: npm, Yarn, pnpm, Bun, Cargo, Go, Gradle, Maven, CocoaPods, pub, pip, uv, Poetry, Homebrew, conda.
- **App caches and logs**: `~/Library/Caches`, sandboxed app caches, caches of Electron apps.
- **Large app data**: Docker and OrbStack disks, Android emulators, iOS backups, local AI models, leftover macOS installers.

Useful options:

```sh
sapu junk ~/Projects --older-than 3m     # only build output of projects untouched for three months
sapu junk --only node_modules,xcode-derived-data --delete
sapu junk --skip system                  # leave app caches alone
sapu junk --delete --dry-run             # show what would happen
```

## `sapu dupes`

```
Duplicates in ~/Pictures
Scanned 58 items (34.7 MB) in 0.0s · read 33.1 MB to compare contents

  1  FOLDER ×4  5.40 MB each · 7 files                                          frees 10.8 MB
     keep    Holiday Photos
     remove  Backup/2023/Holiday Photos
     remove  Holiday Photos (cloned by Finder)
     remove  Holiday Photos copy
  2  FILE ×3  2.50 MB each                                                      frees 5.01 MB
     keep    Documents/installer.dmg
     remove  Downloads/installer (1).dmg
     remove  Downloads/installer.dmg
  3  FOLDER ×2  2.00 MB each · 1 file                                           frees 2.00 MB
     keep    repo/assets  (in a git repository)
     remove  Movies

5 duplicate groups · 22.0 MB can be freed
  5.41 MB more is duplicated in name only: clones and hard links already share their storage
```

Three ways to act on a report:

```sh
sapu dupes ~/Pictures -i         # review every group and tick what should go
sapu dupes ~/Pictures --trash    # move the copies marked "remove" to the Trash
sapu dupes ~/Pictures --clone    # keep every path, store identical data once
```

Which copy stays is decided by `--keep auto` (the default: the one that does not look like a copy, judging by names such as `copy`, `(1)`, `backup`, and by location), `--keep oldest` or `--keep newest`. `--prefer <path>` keeps copies under a folder of your choice.

Other options: `--min-size 100M`, `--files-only`, `--folders-only`, `--hidden`, `--exclude '*.iso'`.

## `sapu big`

```
Space used in ~
Scanned 4,036,514 items in 11s

    352 GB  ~
    183 GB  ├─ Library/                                          ████████░░░░░░░░ 51.9%
   96.7 GB  │  ├─ Application Support/                           ████░░░░░░░░░░░░ 27.4%
   21.2 GB  │  ├─ Containers/                                    █░░░░░░░░░░░░░░░  6.0%
   12.1 GB  │  ├─ Caches/                                        █░░░░░░░░░░░░░░░  3.4%
   53.0 GB  │  └─ (120 smaller items)                            ██░░░░░░░░░░░░░░ 15.1%
    111 GB  ├─ Documents/                                        █████░░░░░░░░░░░ 31.5%
   18.4 GB  ├─ Downloads/                                        █░░░░░░░░░░░░░░░  5.2%
   39.6 GB  └─ (290 smaller items)                               ██░░░░░░░░░░░░░░ 11.3%

Largest files
   30.1 GB  ~/Library/Application Support/Emulator/vms/0/data.qcow2
   16.9 GB  ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
```

Sizes are space on disk, with data shared between clones and hard links counted once, so the numbers add up to what the disk really holds. Options: `--depth 3`, `--top 12`, `--files 30`.

## Safety

Removing the wrong thing is the one mistake a cleaner must not make. These rules are enforced in code and covered by tests:

1. **Report first.** No command changes anything without `-i`, `--trash`, `--delete` or `--clone`, and each of those asks for confirmation unless you add `--yes`. `--dry-run` shows the plan.
2. **One verified copy always stays.** Before a duplicate is removed, `sapu` checks that a different copy from the same group still exists and is unchanged. A selection that would remove every copy is refused. A folder that can be reached through two paths (a firmlink, a volume mounted twice) is recognised as one folder, never as a copy of itself.
3. **Nothing stale is touched.** Right before acting, every file involved is compared with what the scan saw (size, modification time to the nanosecond, inode; for folders, every entry). If anything changed, that item is skipped.
4. **Whole things only.** A copy is never suggested for removal when it is part of something larger: inside a git repository, inside a folder that is a variation of its twin's folder (two versions of one project sharing an `assets` folder), or next to its twin under an unrelated name. Such copies are listed with the reason and can still be ticked by hand.
5. **Tool-managed folders stay intact.** App bundles, `.git`, `node_modules` and other build output are compared as wholes and never picked apart file by file.
6. **System locations are off limits.** `/System`, `/Library`, `/usr`, the top-level folders of your home and similar paths are refused by a guard that every removal passes through.
7. **Cloud files are not downloaded.** Files that exist only in iCloud are skipped; reading them is blocked at the process level.
8. **The Trash is the default destination** for duplicates, so a mistake is one drag away from undone.

`--clone` replaces a duplicate file with an APFS clone of its twin. The clone is compared byte by byte with the file it is about to replace; the path keeps its own permissions, dates, extended attributes and Finder tags; the swap is a single atomic rename. Quit apps that keep such files open (virtual machines, databases) first: a program holding the old file open would go on writing to a file that no longer has a name.

### Known limits

- A change is noticed through size, modification time and inode. A program that alters a file through a memory map without its timestamp moving, between the scan and the removal, goes unnoticed. Files that were matched by APFS clone ID alone are therefore read and compared again right before they are removed.
- Extended attributes other than the resource fork are not compared, so two files that differ only in Finder tags count as identical.
- Junk rules recognise folders by name plus evidence next to or inside them. `review` marks the cases where that evidence cannot rule out something of yours being inside.
- Run it as yourself. `sudo` is not needed and widens what a mistake could reach.

## How it works

**Scanning.** Directories are read with `getattrlistbulk(2)`, which returns names, sizes, timestamps and APFS clone IDs for a whole directory in one call, on several threads. Symlinks are never followed and other volumes are not entered unless asked.

**Duplicate folders.** A folder's identity is a SHA-256 over its sorted entries: name, kind and the identity of each child (for a file, the SHA-256 of its contents; for a symlink, its target). Equal identities mean equal trees. Only the outermost equal folders are reported. `.DS_Store` is ignored; every other hidden file counts, so a folder that differs only by a `.env` is not a duplicate. A file's resource fork is part of its contents; other extended attributes (Finder tags, quarantine flags), permissions and dates are not compared.

**Reading as little as possible.** A file is only read if something could still equal it:

1. Folders are first compared by shape (entry names and file sizes, no reading). A folder whose shape is unique cannot have a twin.
2. Files are grouped by size; a unique size means a unique file.
3. Files that share an APFS clone ID are identical by construction and are never read at all.
4. The rest is compared by a hash of the first and last 64 KB, and only the survivors are hashed in full.

**Honest numbers.** For every group, `sapu` works out which bytes would really be released: a copy that is a clone or hard link of one that stays frees nothing, and is reported that way.

## Questions

**It says some folders could not be read.** macOS protects parts of your home folder. For complete results, add your terminal under System Settings › Privacy & Security › Full Disk Access.

**I deleted 20 GB but free space barely moved.** Three usual reasons: the files are in the Trash (empty it); a local Time Machine snapshot still references them (it expires within a day, and `sapu` tells you when snapshots exist); or the files were clones of something that still exists.

**Does it work on external drives?** Yes: `sapu dupes /Volumes/Backup`. Clone detection and `--clone` need APFS; everything else works on any file system.

**Can I compare two drives or folders?** `sapu dupes /Volumes/A /Volumes/B` reports what they have in common.

**Why did it not suggest removing an obvious duplicate?** It probably has a note in brackets explaining why it was left for you to decide. Use `-i` to tick it yourself.

## Development

```sh
make build      # release build in .build/release/sapu
make test       # unit tests (they create and compare real files in a temp folder)
make dist       # universal binary + tarball in dist/
```

The code is split into `SapuCore` (scanner, duplicate finder, junk rules, actions; no terminal code) and `sapu` (the command-line interface). Junk rules live in [`Sources/SapuCore/Junk/JunkRules.swift`](Sources/SapuCore/Junk/JunkRules.swift): adding a build folder or a cache location is a few lines, and pull requests for tools that are missing are welcome.

## License

[MIT](LICENSE)
