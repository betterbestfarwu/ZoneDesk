import Foundation

public struct FinderIconPoint: Equatable, Sendable {
    public var x: Int16
    public var y: Int16

    public init(x: Int16, y: Int16) {
        self.x = x
        self.y = y
    }
}

public enum FinderInfoCodecError: Error, Equatable, CustomStringConvertible {
    case invalidLength(actual: Int)

    public var description: String {
        switch self {
        case let .invalidLength(actual):
            return "FinderInfo must be exactly 32 bytes, got \(actual) bytes."
        }
    }
}

public enum FinderInfoCodec {
    public static let finderInfoByteCount = 32

    private static let locationYOffset = 10
    private static let locationXOffset = 12

    public static func readLocation(from finderInfo: Data) throws -> FinderIconPoint {
        try validateLength(finderInfo)

        return FinderIconPoint(
            x: readBigEndianInt16(from: finderInfo, offset: locationXOffset),
            y: readBigEndianInt16(from: finderInfo, offset: locationYOffset)
        )
    }

    public static func writeLocation(_ point: FinderIconPoint, into finderInfo: inout Data) throws {
        try validateLength(finderInfo)

        writeBigEndianInt16(point.y, into: &finderInfo, offset: locationYOffset)
        writeBigEndianInt16(point.x, into: &finderInfo, offset: locationXOffset)
    }

    public static func replacingLocation(_ point: FinderIconPoint, in finderInfo: Data) throws -> Data {
        var copy = finderInfo
        try writeLocation(point, into: &copy)
        return copy
    }

    private static func validateLength(_ finderInfo: Data) throws {
        guard finderInfo.count == finderInfoByteCount else {
            throw FinderInfoCodecError.invalidLength(actual: finderInfo.count)
        }
    }

    private static func readBigEndianInt16(from data: Data, offset: Int) -> Int16 {
        let raw = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        return Int16(bitPattern: raw)
    }

    private static func writeBigEndianInt16(_ value: Int16, into data: inout Data, offset: Int) {
        let raw = UInt16(bitPattern: value)
        data[offset] = UInt8((raw >> 8) & 0xFF)
        data[offset + 1] = UInt8(raw & 0xFF)
    }
}
