import Foundation
import CZlib

public enum WindogError: LocalizedError {
    case invalid(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid .windog file: \(reason)"
        case .unsupported(let reason): return "Unsupported .windog feature: \(reason)"
        }
    }
}

/// The observed ordinary compressed variant only. Payloads remain opaque here.
public enum WindogContainer {
    public static let maximumPayloadSize = 256 * 1024 * 1024
    private static let magic = Data([0x61, 0x6b, 0x7a, 0x01])

    public static func decode(_ data: Data) throws -> Data {
        guard data.count >= 12 else { throw WindogError.invalid("truncated container header") }
        guard data.prefix(4) == magic else {
            throw WindogError.unsupported("expected the ordinary akz01 compressed container")
        }
        let size = Int(data.uint32(at: 4))
        guard size > 0, size <= maximumPayloadSize else {
            throw WindogError.invalid("payload length exceeds supported bounds")
        }
        let compressed = Data(data.dropFirst(12))
        guard checksum(compressed) == data.uint32(at: 8) else {
            throw WindogError.invalid("compressed-data Adler-32 mismatch")
        }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WindogError.invalid("cannot initialize zlib")
        }
        defer { inflateEnd(&stream) }
        // One extra byte detects an incorrect declared length without unbounded expansion.
        var payload = Data(count: size + 1)
        let status = payload.withUnsafeMutableBytes { output in
            compressed.withUnsafeBytes { input in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(size + 1)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size,
              stream.total_in == compressed.count else {
            throw WindogError.invalid("truncated zlib stream, trailing data, or length mismatch")
        }
        payload.removeLast()
        return payload
    }

    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumPayloadSize else {
            throw WindogError.invalid("payload length exceeds supported bounds")
        }
        var length = compressBound(uLong(payload.count))
        var compressed = Data(count: Int(length))
        let status = compressed.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes { input in
                compress2(output.bindMemory(to: Bytef.self).baseAddress, &length,
                          input.bindMemory(to: Bytef.self).baseAddress,
                          uLong(payload.count), Z_DEFAULT_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw WindogError.invalid("zlib compression failed") }
        compressed.count = Int(length)
        var result = magic
        result.appendUInt32(UInt32(payload.count))
        result.appendUInt32(checksum(compressed))
        result.append(compressed)
        return result
    }

    public static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(adler32(1, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
        }
    }
}

extension Data {
    func uint32(at offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
