import Foundation
import SapuCore

struct UsageError: Error {
    let message: String
}

/// What a command accepts: boolean flags, options that take a value, and single-letter aliases.
struct ArgumentSpec {
    var flags: Set<String>
    var options: Set<String>
    var short: [Character: String] = [:]
}

struct Arguments {
    private(set) var flags = Set<String>()
    private(set) var options: [String: [String]] = [:]
    private(set) var positionals: [String] = []

    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ option: String) -> String? { options[option]?.last }
    func values(_ option: String) -> [String] { options[option] ?? [] }

    init(_ raw: [String], spec: ArgumentSpec) throws {
        var index = 0
        var onlyPositionals = false

        func takeValue(for name: String, inline: String?) throws -> String {
            if let inline { return inline }
            index += 1
            guard index < raw.count else { throw UsageError(message: "--\(name) needs a value") }
            return raw[index]
        }

        func accept(_ name: String, inline: String?) throws {
            if spec.flags.contains(name) {
                guard inline == nil else { throw UsageError(message: "--\(name) does not take a value") }
                flags.insert(name)
            } else if spec.options.contains(name) {
                options[name, default: []].append(try takeValue(for: name, inline: inline))
            } else {
                throw UsageError(message: "unknown option --\(name)")
            }
        }

        while index < raw.count {
            let argument = raw[index]
            if onlyPositionals || argument == "-" || !argument.hasPrefix("-") {
                positionals.append(argument)
            } else if argument == "--" {
                onlyPositionals = true
            } else if argument.hasPrefix("--") {
                let body = argument.dropFirst(2)
                if let equals = body.firstIndex(of: "=") {
                    try accept(String(body[..<equals]), inline: String(body[body.index(after: equals)...]))
                } else {
                    try accept(String(body), inline: nil)
                }
            } else {
                // Short form: -i, -iy, -n 20
                let letters = Array(argument.dropFirst())
                for (position, letter) in letters.enumerated() {
                    guard let name = spec.short[letter] else { throw UsageError(message: "unknown option -\(letter)") }
                    if spec.options.contains(name) {
                        let rest = String(letters[(position + 1)...])
                        options[name, default: []].append(try takeValue(for: name, inline: rest.isEmpty ? nil : rest))
                        break
                    }
                    flags.insert(name)
                }
            }
            index += 1
        }
    }

    // MARK: - Typed access

    func size(_ option: String, default fallback: Int64) throws -> Int64 {
        guard let text = value(option) else { return fallback }
        guard let parsed = ByteSize.parse(text) else {
            throw UsageError(message: "--\(option): '\(text)' is not a size (try 500k, 10M, 1.5G)")
        }
        return parsed
    }

    func integer(_ option: String, default fallback: Int) throws -> Int {
        guard let text = value(option) else { return fallback }
        guard let parsed = Int(text), parsed >= 0 else { throw UsageError(message: "--\(option): '\(text)' is not a number") }
        return parsed
    }

    /// Scan roots from the positional arguments, resolved and without overlaps.
    func roots(default fallback: String) throws -> [String] {
        let inputs = positionals.isEmpty ? [fallback] : positionals
        var roots: [String] = []
        for input in inputs {
            guard let resolved = PathUtil.normalize(input) else { throw UsageError(message: "no such file or directory: \(input)") }
            roots.append(resolved)
        }
        return PathUtil.dedupeRoots(roots)
    }
}
