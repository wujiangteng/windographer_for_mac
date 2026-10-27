import Foundation

/// A scalar-based delimited reader used only to verify exported bytes. This is
/// deliberately independent of the production writer and text importer.
enum IndependentDelimitedReader {
    static func read(_ url: URL, delimiter: Unicode.Scalar) throws -> [[String]] {
        var text = try String(contentsOf: url, encoding: .utf8)
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let scalars = Array(text.unicodeScalars)
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closedQuote = false, pendingRow = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if quoted {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\""); index += 1
                    } else { quoted = false; closedQuote = true }
                } else { field.unicodeScalars.append(scalar) }
            } else if scalar == delimiter {
                row.append(field); field = ""; closedQuote = false; pendingRow = true
            } else if scalar == "\r" || scalar == "\n" {
                row.append(field); rows.append(row)
                row = []; field = ""; closedQuote = false; pendingRow = false
                if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
            } else if scalar == "\"", field.isEmpty, !closedQuote {
                quoted = true; pendingRow = true
            } else {
                guard !closedQuote, scalar != "\"" else { throw ReaderError.malformedQuoting }
                field.unicodeScalars.append(scalar); pendingRow = true
            }
            index += 1
        }
        guard !quoted else { throw ReaderError.malformedQuoting }
        if pendingRow || !row.isEmpty || !field.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    enum ReaderError: Error { case malformedQuoting }
}

/// macOS's independent ZIP implementation validates entries and their CRCs on
/// extraction. It does not depend on Python or on the production ZIP writer.
enum IndependentZIPReader {
    static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReaderError.unzipFailed(process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    enum ReaderError: Error { case unzipFailed(Int32, String) }
}
