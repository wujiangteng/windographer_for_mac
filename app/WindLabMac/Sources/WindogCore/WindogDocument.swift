import Foundation
import CoreFoundation

private let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

private struct ArchiveString: Sendable {
    let text: String
    let range: Range<Int>
    let encoding: String.Encoding

    func encoded(_ value: String) throws -> Data {
        guard !value.contains("\0"), let bytes = value.data(using: encoding, allowLossyConversion: false) else {
            throw WindogError.unsupported("text cannot be represented in the original field encoding")
        }
        let count = encoding == .utf16LittleEndian ? bytes.count / 2 : bytes.count
        guard count < 65534 else { throw WindogError.unsupported("text is too long") }
        var result = Data()
        if encoding == .utf16LittleEndian { result.append(contentsOf: [255, 254, 255]) }
        if count < 255 {
            result.append(UInt8(count))
        } else {
            result.append(255)
            result.append(UInt8(count & 255))
            result.append(UInt8(count >> 8))
        }
        result.append(bytes)
        return result
    }
}

private struct ArchiveReader {
    let data: Data
    var offset: Int = 0

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset <= data.count - count else { throw WindogError.invalid("truncated archive") }
        offset += count
    }

    mutating func byte() throws -> UInt8 {
        let start = offset
        try skip(1)
        return data[start]
    }

    mutating func word() throws -> UInt16 {
        let start = offset
        try skip(2)
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    mutating func integer() throws -> UInt32 {
        let start = offset
        try skip(4)
        return data.uint32(at: start)
    }

    mutating func double() throws -> Double {
        let low = UInt64(try integer())
        let high = UInt64(try integer())
        return Double(bitPattern: low | high << 32)
    }

    mutating func string(unit: Bool = false) throws -> ArchiveString {
        let start = offset
        var length = Int(try byte())
        var unicode = false
        if length == 255 {
            length = Int(try word())
            if length == 65534 {
                unicode = true
                length = Int(try byte())
                if length == 255 { length = Int(try word()) }
            }
            if length == 65535 { length = Int(try integer()) }
        }
        guard length <= 1_048_576 else { throw WindogError.invalid("archive string exceeds bounds") }
        let contentStart = offset
        try skip(length * (unicode ? 2 : 1))
        let bytes = Data(data[contentStart..<offset])
        let encoding: String.Encoding
        if unicode {
            encoding = .utf16LittleEndian
        } else if unit && (bytes == Data([0xb0]) || bytes == Data([0xb0, 0x43])) {
            encoding = .windowsCP1252
        } else if String(data: bytes, encoding: gb18030) != nil {
            encoding = gb18030
        } else {
            encoding = .windowsCP1252
        }
        guard let text = String(data: bytes, encoding: encoding), !text.contains("\0") else {
            throw WindogError.invalid("invalid archive string")
        }
        return ArchiveString(text: text, range: start..<offset, encoding: encoding)
    }
}

public struct WindogFlag: Decodable, Sendable {
    public let id: UInt16
    public let name: String
    public let description: String
    public let color: UInt32
}

public struct WindogColumn: Sendable {
    public let index: Int
    /// Unique within this document, even when native display names are duplicated.
    public let channelID: String
    public var name: String { nameField.text }
    public let originalName: String
    public var unit: String { unitField.text }
    public let color: UInt32
    public let reference: UInt32
    public let count: Int
    public let dataRange: Range<Int>
    fileprivate let nameField: ArchiveString
    fileprivate let unitField: ArchiveString
    fileprivate let recordOffset: Int
}

public struct WindogColumnEdit: Sendable {
    public let index: Int
    public let name: String
    public let unit: String

    public init(index: Int, name: String, unit: String) {
        self.index = index
        self.name = name
        self.unit = unit
    }
}

/// Schema-22 document with observed schema-7 column headers. Unknown bytes are
/// retained intact; unresolved column tails are never synthesized or discarded.
public struct WindogDocument: Sendable {
    public let payload: Data
    public let writerVersion: String
    public let startDate: Date
    public let timeStepMinutes: Int
    public let flags: [WindogFlag]
    public let columns: [WindogColumn]
    private let originalContainer: Data?

    public init(contentsOf url: URL) throws {
        try self.init(container: Data(contentsOf: url))
    }

    public init(container: Data) throws {
        try self.init(payload: WindogContainer.decode(container), originalContainer: container)
    }

    public init(payload: Data) throws {
        try self.init(payload: payload, originalContainer: nil)
    }

    private init(payload: Data, originalContainer: Data?) throws {
        guard payload.count <= WindogContainer.maximumPayloadSize else {
            throw WindogError.invalid("archive exceeds bounds")
        }
        var reader = ArchiveReader(data: payload)
        guard try reader.string().text == "Windographer" else {
            throw WindogError.invalid("archive producer is not Windographer")
        }
        writerVersion = try reader.string().text
        guard try reader.integer() == 22 else { throw WindogError.unsupported("document schema must be 22") }
        guard try reader.integer() == 2, try reader.integer() == 0 else {
            throw WindogError.unsupported("unrecognized data archive header")
        }
        let oleDate = try reader.double()
        guard oleDate.isFinite, (1...80_000).contains(oleDate) else {
            throw WindogError.invalid("invalid start date")
        }
        startDate = Date(timeIntervalSince1970: (oleDate - 25_569) * 86_400)
        timeStepMinutes = Int(try reader.integer())
        guard timeStepMinutes > 0, timeStepMinutes <= 1440 else {
            throw WindogError.unsupported("invalid time step")
        }
        try reader.skip(4)
        guard try reader.integer() == 1 else { throw WindogError.unsupported("flag collection version") }
        let flagCount = Int(try reader.word())
        guard flagCount <= 10_000 else { throw WindogError.invalid("too many flags") }
        var flags: [WindogFlag] = []
        for _ in 0..<flagCount {
            guard try reader.byte() == 5 else { throw WindogError.unsupported("flag structure version") }
            let id = try reader.word()
            let name = try reader.string().text
            let description = try reader.string().text
            let color = try reader.integer()
            try reader.skip(2)
            flags.append(WindogFlag(id: id, name: name, description: description, color: color))
        }
        self.flags = flags
        try reader.skip(6)
        let columnCount = Int(try reader.integer())
        guard columnCount > 0, columnCount <= 10_000 else { throw WindogError.invalid("invalid column count") }
        let firstColumnOffset = reader.offset
        var searchOffset = firstColumnOffset
        var columns: [WindogColumn] = []
        var names: Set<String> = []
        let marker = Data([7, 0, 0, 0])
        // Column tails remain undocumented. Search only outside validated arrays;
        // require the declared count and first-column boundary before accepting.
        while searchOffset <= payload.count - 4,
              let match = payload.range(of: marker, in: searchOffset..<payload.count) {
            let start = match.lowerBound
            searchOffset = start + 1
            do {
                var candidate = ArchiveReader(data: payload, offset: start + 4)
                let name = try candidate.string()
                let originalName = try candidate.string()
                let unit = try candidate.string(unit: true)
                guard !name.text.isEmpty, !name.text.unicodeScalars.contains(where: { $0.value < 32 }) else { continue }
                let color = try candidate.integer()
                let reference = try candidate.integer()
                guard reference == UInt32.max || (900..<100_000).contains(reference) else { continue }
                let count = Int(try candidate.integer())
                let dataStart = candidate.offset
                guard count <= (payload.count - dataStart) / 4 else { continue }
                try candidate.skip(count * 4)
                var id = name.text
                var suffix = 2
                while names.contains(id) { id = "\(name.text) [\(suffix)]"; suffix += 1 }
                names.insert(id)
                columns.append(WindogColumn(index: columns.count, channelID: id,
                                            originalName: originalName.text, color: color,
                                            reference: reference, count: count,
                                            dataRange: dataStart..<candidate.offset,
                                            nameField: name, unitField: unit, recordOffset: start))
                searchOffset = candidate.offset
            } catch {
                continue
            }
        }
        guard columns.count == columnCount, columns.first?.recordOffset == firstColumnOffset else {
            throw WindogError.unsupported("column layout is not fully recognized (\(columns.count)/\(columnCount)); no partial load")
        }
        self.columns = columns
        self.payload = payload
        self.originalContainer = originalContainer
    }

    public func values(for column: WindogColumn) -> [Float] {
        payload.withUnsafeBytes { bytes in
            (0..<column.count).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: column.dataRange.lowerBound + $0 * 4, as: UInt32.self)))
            }
        }
    }

    public func applying(_ edits: [WindogColumnEdit]) throws -> WindogDocument {
        var replacements: [(Range<Int>, Data)] = []
        var edited: Set<Int> = []
        for edit in edits {
            guard columns.indices.contains(edit.index), edited.insert(edit.index).inserted else {
                throw WindogError.invalid("invalid or duplicated column edit")
            }
            guard !edit.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WindogError.invalid("column name cannot be empty")
            }
            let column = columns[edit.index]
            if edit.name != column.name {
                replacements.append((column.nameField.range, try column.nameField.encoded(edit.name)))
            }
            if edit.unit != column.unit {
                replacements.append((column.unitField.range, try column.unitField.encoded(edit.unit)))
            }
        }
        if replacements.isEmpty { return self }
        var updated = payload
        for (range, bytes) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            updated.replaceSubrange(range, with: bytes)
        }
        return try WindogDocument(payload: updated)
    }

    public func encoded() throws -> Data {
        try originalContainer ?? WindogContainer.encode(payload)
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}
