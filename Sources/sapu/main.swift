import Darwin
import Foundation
import SapuCore

let version = "0.1.0"

let usage = """
sapu \(version) — sweep your Mac's disk clean, safely

USAGE
  sapu <command> [options]

COMMANDS
  status   Disk space at a glance (the default)
  junk     Caches, build output and other data that can be regenerated
  dupes    Identical folders and files
  big      What is taking the space

Every command only reports until you add -i (choose interactively) or an explicit
action such as --trash or --delete. Run `sapu <command> --help` for details.
"""

func status() -> Int32 {
    print("sapu \(version)".bold + " — sweep your Mac's disk clean, safely".dim)
    print("")
    if let volume = VolumeInfo.of(path: PathUtil.home) {
        let fraction = Double(volume.used) / Double(max(volume.total, 1))
        let bar = Format.bar(fraction: fraction, width: 30)
        let colored = fraction > 0.9 ? bar.red : fraction > 0.75 ? bar.yellow : bar.green
        print("\(volume.name.bold)  \(colored)  \(Format.size(volume.used)) used of \(Format.size(volume.total))")
        var line = "\(Format.size(volume.free)) free"
        if volume.purgeable > 0 { line += " · \(Format.size(volume.purgeable)) more can be purged by macOS on demand" }
        print(fraction > 0.9 ? line.red : line)
        let snapshots = VolumeInfo.localSnapshotCount()
        if snapshots > 0 {
            print("\(Format.plural(snapshots, "local Time Machine snapshot")) may hold on to deleted data for up to a day.".dim)
        }
        print("")
    }
    print("Where to start".bold)
    print("  sapu junk".bold + "    caches, build output and other regenerable data (usually the quickest win)".dim)
    print("  sapu dupes".bold + "   identical folders and files".dim)
    print("  sapu big".bold + "     what is taking the space".dim)
    print("")
    print("Each command only reports. Add -i to pick what to remove, or --help for options.".dim)
    return 0
}

func main() -> Int32 {
    // Reading a cloud-only file must never trigger its download.
    VolumeInfo.neverMaterializeCloudFiles()
    // Restore the cursor if a scan is interrupted.
    signal(SIGINT) { _ in
        let reset = "\r\u{1B}[2K\u{1B}[?25h"
        _ = reset.withCString { write(STDERR_FILENO, $0, strlen($0)) }
        _exit(130)
    }

    if geteuid() == 0 {
        Term.error("running as root is not needed and not recommended; sapu is meant to clean your own files")
    }

    var arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
    if command != nil { arguments.removeFirst() }

    do {
        switch command {
        case nil:
            if arguments.contains("--version") || arguments.contains("-V") {
                print(version)
                return 0
            }
            if arguments.contains("--help") || arguments.contains("-h") {
                print(usage)
                return 0
            }
            guard arguments.isEmpty else { throw UsageError(message: "unknown option \(arguments[0])") }
            return status()
        case "status": return status()
        case "dupes", "dupe", "duplicates": return try DupesCommand.run(arguments)
        case "junk", "clean": return try JunkCommand.run(arguments)
        case "big", "large", "space": return try BigCommand.run(arguments)
        case "version":
            print(version)
            return 0
        case "help":
            switch arguments.first {
            case "dupes": print(DupesCommand.help)
            case "junk": print(JunkCommand.help)
            case "big": print(BigCommand.help)
            default: print(usage)
            }
            return 0
        default:
            throw UsageError(message: "unknown command '\(command!)'")
        }
    } catch let error as UsageError {
        Term.error(error.message)
        FileHandle.standardError.write(Data("Try `sapu --help`.\n".utf8))
        return 2
    } catch {
        Term.error("\(error)")
        return 1
    }
}

exit(main())
