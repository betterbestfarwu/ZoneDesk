import Foundation

public enum FinderInfoHexError: Error, Equatable, CustomStringConvertible {
    case oddLength
    case invalidCharacter(String)

    public var description: String {
        switch self {
        case .oddLength:
            return "Hex string must contain an even number of hexadecimal digits."
        case let .invalidCharacter(character):
            return "Invalid hexadecimal character: \(character)"
        }
    }
}

public enum FinderInfoHex {
    public static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(_ hex: String) throws -> Data {
        let nibbles = try hex.unicodeScalars.compactMap { scalar -> UInt8? in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return nil
            }

            guard let value = hexDigitValue(for: scalar) else {
                throw FinderInfoHexError.invalidCharacter(String(scalar))
            }

            return UInt8(value)
        }

        guard nibbles.count.isMultiple(of: 2) else {
            throw FinderInfoHexError.oddLength
        }

        var bytes = Data()
        bytes.reserveCapacity(nibbles.count / 2)

        for index in stride(from: 0, to: nibbles.count, by: 2) {
            bytes.append((nibbles[index] << 4) | nibbles[index + 1])
        }

        return bytes
    }

    private static func hexDigitValue(for scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 48...57:
            return UInt8(scalar.value - 48)
        case 65...70:
            return UInt8(scalar.value - 55)
        case 97...102:
            return UInt8(scalar.value - 87)
        default:
            return nil
        }
    }
}
