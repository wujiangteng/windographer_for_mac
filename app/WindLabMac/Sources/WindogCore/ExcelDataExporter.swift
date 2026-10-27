import Foundation
import CZlib
import Darwin

/// Modern OOXML output for WindLab. This is not an implementation of the legacy
/// Excel/OLE writer found in Windographer. Worksheets stream to a ZIP32 archive.
public enum ExcelDataExporter {
    public static func write(_ dataset: WindExportDataSet, to url: URL) throws {
        try dataset.validate()
        guard dataset.rowCount < 1_048_576, dataset.columns.count < 16_384 else {
            throw WindogError.unsupported("Excel supports at most 1,048,575 data rows and 16,383 data columns plus timestamps")
        }
        guard dataset.startDate.timeIntervalSince1970.isFinite else {
            throw WindogError.invalid("invalid export start date")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".windlab-xlsx-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw WindogError.invalid("cannot create workbook output")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = try WorkbookZIP(url: temporary)
        do {
            try archive.add("[Content_Types].xml", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
            """)
            try archive.add("_rels/.rels", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """)
            try archive.add("xl/workbook.xml", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>
            """)
            try archive.add("xl/_rels/workbook.xml.rels", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """)
            try archive.add("xl/worksheets/sheet1.xml") { emit in
                var buffer = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
                func flush() throws {
                    try emit(Data(buffer.utf8))
                    buffer.removeAll(keepingCapacity: true)
                }
                let headings = ["Date/Time"] + dataset.columns.map(\.heading)
                let letters = headings.indices.map(columnLetters)
                buffer += "<row r=\"1\">"
                for (index, heading) in headings.enumerated() {
                    buffer += try inlineCell(reference: "\(letters[index])1", text: heading)
                }
                buffer += "</row>"
                let formatter = WindExportNumbers.dateFormatter()
                let interval = Double(dataset.timeStepMinutes) * 60
                for row in 0..<dataset.rowCount {
                    let number = row + 2
                    let date = dataset.startDate.addingTimeInterval(Double(row) * interval)
                    buffer += "<row r=\"\(number)\">"
                    buffer += try inlineCell(reference: "A\(number)", text: formatter.string(from: date))
                    for (columnIndex, column) in dataset.columns.enumerated() {
                        if row < column.values.count, let value = column.values[row], value.isFinite {
                            buffer += "<c r=\"\(letters[columnIndex + 1])\(number)\" t=\"n\"><v>\(WindExportNumbers.string(value))</v></c>"
                        }
                    }
                    buffer += "</row>"
                    if buffer.utf8.count >= 262_144 { try flush() }
                }
                buffer += "</sheetData></worksheet>"
                try flush()
            }
            try archive.finish()
        } catch {
            archive.close()
            throw error
        }
        // Same-directory rename atomically replaces an existing user-selected file.
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { destination in Darwin.rename(source!, destination!) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private static func columnLetters(_ index: Int) -> String {
        var value = index + 1
        var result = ""
        while value > 0 {
            value -= 1
            result = String(UnicodeScalar(65 + value % 26)!) + result
            value /= 26
        }
        return result
    }

    private static func inlineCell(reference: String, text: String) throws -> String {
        guard text.utf16.count <= 32_767 else { throw WindogError.unsupported("Excel cell text exceeds 32,767 characters") }
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 38: escaped += "&amp;"
            case 60: escaped += "&lt;"
            case 62: escaped += "&gt;"
            case 34: escaped += "&quot;"
            case 39: escaped += "&apos;"
            case 9, 10, 13, 32...0xd7ff, 0xe000...0xfffd, 0x10000...0x10ffff:
                escaped.unicodeScalars.append(scalar)
            default: throw WindogError.unsupported("Excel headers contain invalid XML control characters")
            }
        }
        return "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escaped)</t></is></c>"
    }
}

private final class WorkbookZIP {
    private struct Entry {
        let name: Data
        let checksum: UInt32
        let size: UInt32
        let offset: UInt32
    }
    private let handle: FileHandle
    private var entries: [Entry] = []
    private var position: UInt64 = 0

    init(url: URL) throws { handle = try FileHandle(forWritingTo: url) }

    func close() { try? handle.close() }

    private func write(_ data: Data) throws {
        guard position + UInt64(data.count) <= UInt64(UInt32.max) else {
            throw WindogError.unsupported("workbook exceeds the supported ZIP32 size")
        }
        try handle.write(contentsOf: data)
        position += UInt64(data.count)
    }

    private func fields(_ values: [(UInt32, Int)]) throws {
        var data = Data()
        for (value, size) in values {
            for shift in 0..<size { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        try write(data)
    }

    func add(_ name: String, text: String) throws {
        try add(name) { emit in try emit(Data(text.utf8)) }
    }

    func add(_ name: String, body: (_ emit: (Data) throws -> Void) throws -> Void) throws {
        let filename = Data(name.utf8)
        let offset = UInt32(position)
        // Bit 3 = trailing descriptor; bit 11 = UTF-8 names. Method 0 is stored.
        try fields([(0x04034b50, 4), (20, 2), (0x0808, 2), (0, 2), (0, 2), (33, 2),
                    (0, 4), (0, 4), (0, 4), (UInt32(filename.count), 2), (0, 2)])
        try write(filename)
        var checksum: UInt32 = 0
        var size: UInt64 = 0
        try body { data in
            checksum = data.withUnsafeBytes {
                UInt32(crc32(uLong(checksum), $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
            }
            size += UInt64(data.count)
            try write(data)
        }
        let entry = Entry(name: filename, checksum: checksum, size: UInt32(size), offset: offset)
        try fields([(0x08074b50, 4), (checksum, 4), (entry.size, 4), (entry.size, 4)])
        entries.append(entry)
    }

    func finish() throws {
        let directoryStart = UInt32(position)
        for entry in entries {
            try fields([(0x02014b50, 4), (20, 2), (20, 2), (0x0808, 2), (0, 2), (0, 2), (33, 2),
                        (entry.checksum, 4), (entry.size, 4), (entry.size, 4),
                        (UInt32(entry.name.count), 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (entry.offset, 4)])
            try write(entry.name)
        }
        let directorySize = UInt32(position) - directoryStart
        try fields([(0x06054b50, 4), (0, 2), (0, 2), (UInt32(entries.count), 2),
                    (UInt32(entries.count), 2), (directorySize, 4), (directoryStart, 4), (0, 2)])
        try handle.synchronize()
        try handle.close()
    }
}
