import Darwin
import Foundation

public enum FinderInfoXattrError: Error, CustomStringConvertible {
    case attributeMissing(path: String)
    case posix(function: String, path: String, errnoCode: Int32)

    public var description: String {
        switch self {
        case let .attributeMissing(path):
            return "FinderInfo xattr is missing for \(path)."
        case let .posix(function, path, errnoCode):
            return "\(function) failed for \(path): errno \(errnoCode) (\(String(cString: strerror(errnoCode))))"
        }
    }
}

public enum FinderInfoXattrStore {
    public static let attributeName = "com.apple.FinderInfo"

    public static func read(from url: URL) throws -> Data {
        try withPathAndAttributeName(url: url) { pathPointer, attributePointer in
            let size = getxattr(pathPointer, attributePointer, nil, 0, 0, 0)
            guard size >= 0 else {
                let errnoCode = errno
                if errnoCode == ENOATTR {
                    throw FinderInfoXattrError.attributeMissing(path: url.path)
                }
                throw FinderInfoXattrError.posix(function: "getxattr(size)", path: url.path, errnoCode: errnoCode)
            }

            let byteCount = Int(size)
            var data = Data(count: byteCount)
            let bytesRead = data.withUnsafeMutableBytes { buffer in
                getxattr(pathPointer, attributePointer, buffer.baseAddress, byteCount, 0, 0)
            }

            guard bytesRead >= 0 else {
                throw FinderInfoXattrError.posix(function: "getxattr(data)", path: url.path, errnoCode: errno)
            }

            guard bytesRead == FinderInfoCodec.finderInfoByteCount else {
                throw FinderInfoCodecError.invalidLength(actual: Int(bytesRead))
            }

            return data
        }
    }

    public static func readOrEmpty(from url: URL) throws -> Data {
        do {
            return try read(from: url)
        } catch FinderInfoXattrError.attributeMissing {
            return Data(repeating: 0, count: FinderInfoCodec.finderInfoByteCount)
        }
    }

    public static func write(_ finderInfo: Data, to url: URL) throws {
        guard finderInfo.count == FinderInfoCodec.finderInfoByteCount else {
            throw FinderInfoCodecError.invalidLength(actual: finderInfo.count)
        }

        try withPathAndAttributeName(url: url) { pathPointer, attributePointer in
            let result = finderInfo.withUnsafeBytes { buffer in
                setxattr(pathPointer, attributePointer, buffer.baseAddress, finderInfo.count, 0, 0)
            }

            guard result == 0 else {
                throw FinderInfoXattrError.posix(function: "setxattr", path: url.path, errnoCode: errno)
            }
        }
    }

    public static func remove(from url: URL) throws {
        try withPathAndAttributeName(url: url) { pathPointer, attributePointer in
            let result = removexattr(pathPointer, attributePointer, 0)
            guard result == 0 else {
                let errnoCode = errno
                if errnoCode == ENOATTR {
                    return
                }
                throw FinderInfoXattrError.posix(function: "removexattr", path: url.path, errnoCode: errnoCode)
            }
        }
    }

    private static func withPathAndAttributeName<T>(
        url: URL,
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) throws -> T
    ) throws -> T {
        try url.path.withCString { pathPointer in
            try attributeName.withCString { attributePointer in
                try body(pathPointer, attributePointer)
            }
        }
    }
}
