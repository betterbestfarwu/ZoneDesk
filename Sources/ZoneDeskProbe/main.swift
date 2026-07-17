import Foundation
import ZoneDeskCore

let toolName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "zonedesk-probe"
let arguments = Array(CommandLine.arguments.dropFirst())

do {
    try run(arguments: arguments)
} catch {
    fputs("error: \(error)\n", stderr)
    fputs("\n\(usage())\n", stderr)
    Foundation.exit(1)
}

func run(arguments: [String]) throws {
    guard let command = arguments.first else {
        print(usage())
        return
    }

    switch command {
    case "read":
        guard arguments.count == 2 else {
            throw ProbeError.invalidArguments("read requires <path>")
        }
        try read(path: arguments[1])

    case "write":
        guard arguments.count == 4 || arguments.count == 5 else {
            throw ProbeError.invalidArguments("write requires <path> <x> <y> [--apply]")
        }
        try write(path: arguments[1], x: arguments[2], y: arguments[3], apply: arguments.contains("--apply"))

    case "restore":
        guard arguments.count == 3 || arguments.count == 4 else {
            throw ProbeError.invalidArguments("restore requires <path> <finder-info-hex> [--apply]")
        }
        try restore(path: arguments[1], hex: arguments[2], apply: arguments.contains("--apply"))

    case "clear":
        guard arguments.count == 2 || arguments.count == 3 else {
            throw ProbeError.invalidArguments("clear requires <path> [--apply]")
        }
        try clear(path: arguments[1], apply: arguments.contains("--apply"))

    case "help", "--help", "-h":
        print(usage())

    default:
        throw ProbeError.invalidArguments("unknown command: \(command)")
    }
}

func read(path: String) throws {
    let url = URL(fileURLWithPath: path)
    let finderInfo: Data
    let status: String

    do {
        finderInfo = try FinderInfoXattrStore.read(from: url)
        status = "present"
    } catch FinderInfoXattrError.attributeMissing {
        finderInfo = Data(repeating: 0, count: FinderInfoCodec.finderInfoByteCount)
        status = "missing; showing zeroed fallback"
    }

    let point = try FinderInfoCodec.readLocation(from: finderInfo)
    print("path: \(url.path)")
    print("FinderInfo: \(status)")
    print("location: x=\(point.x), y=\(point.y)")
    print("hex: \(FinderInfoHex.encode(finderInfo))")
}

func write(path: String, x: String, y: String, apply: Bool) throws {
    let url = URL(fileURLWithPath: path)
    let point = FinderIconPoint(
        x: try parseInt16(x, label: "x"),
        y: try parseInt16(y, label: "y")
    )

    let original: Data
    let restoreCommand: String

    do {
        original = try FinderInfoXattrStore.read(from: url)
        restoreCommand = "\(toolName) restore \(shellQuote(url.path)) \(FinderInfoHex.encode(original)) --apply"
    } catch FinderInfoXattrError.attributeMissing {
        original = Data(repeating: 0, count: FinderInfoCodec.finderInfoByteCount)
        restoreCommand = "\(toolName) clear \(shellQuote(url.path)) --apply"
    }

    let originalPoint = try FinderInfoCodec.readLocation(from: original)
    let updated = try FinderInfoCodec.replacingLocation(point, in: original)

    print("path: \(url.path)")
    print("before: x=\(originalPoint.x), y=\(originalPoint.y)")
    print("after:  x=\(point.x), y=\(point.y)")
    print("restore: \(restoreCommand)")

    guard apply else {
        print("dry-run: no changes written. Re-run with --apply to write FinderInfo.")
        return
    }

    try FinderInfoXattrStore.write(updated, to: url)
    notifyFinderIconChanged(path: url.path)
    print("applied: FinderInfo written.")
}

func restore(path: String, hex: String, apply: Bool) throws {
    let url = URL(fileURLWithPath: path)
    let finderInfo = try FinderInfoHex.decode(hex)
    _ = try FinderInfoCodec.readLocation(from: finderInfo)

    print("path: \(url.path)")
    print("restore location: x=\(try FinderInfoCodec.readLocation(from: finderInfo).x), y=\(try FinderInfoCodec.readLocation(from: finderInfo).y)")

    guard apply else {
        print("dry-run: no changes written. Re-run with --apply to restore FinderInfo.")
        return
    }

    try FinderInfoXattrStore.write(finderInfo, to: url)
    notifyFinderIconChanged(path: url.path)
    print("applied: FinderInfo restored.")
}

func clear(path: String, apply: Bool) throws {
    let url = URL(fileURLWithPath: path)
    print("path: \(url.path)")

    guard apply else {
        print("dry-run: no changes written. Re-run with --apply to remove FinderInfo xattr.")
        return
    }

    try FinderInfoXattrStore.remove(from: url)
    notifyFinderIconChanged(path: url.path)
    print("applied: FinderInfo xattr removed.")
}

func parseInt16(_ rawValue: String, label: String) throws -> Int16 {
    guard let value = Int16(rawValue) else {
        throw ProbeError.invalidArguments("\(label) must be a signed 16-bit integer: \(rawValue)")
    }
    return value
}

func notifyFinderIconChanged(path: String) {
    DistributedNotificationCenter.default().post(
        name: Notification.Name("com.apple.finder.iconChanged"),
        object: path
    )
}

func usage() -> String {
    """
    Usage:
      \(toolName) read <path>
      \(toolName) write <path> <x> <y> [--apply]
      \(toolName) restore <path> <finder-info-hex> [--apply]
      \(toolName) clear <path> [--apply]

    Notes:
      - write/restore/clear are dry-run by default.
      - Use read before write to capture the original FinderInfo hex.
      - Coordinates are written to FinderInfo FileInfo.location bytes 10-13.
    """
}

func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)

    var description: String {
        switch self {
        case let .invalidArguments(message):
            return message
        }
    }
}
