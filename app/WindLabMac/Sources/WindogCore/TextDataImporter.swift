import Foundation
import CoreFoundation

/// Reads delimited logger tables directly in Swift. Wall-clock
/// timestamps are represented in UTC, as elsewhere in WindogCore.
public enum TextDataImporter {
    public static func load(contentsOf url: URL) throws -> WindExportDataSet {
        try parse(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(data: Data, name: String) throws -> WindExportDataSet {
        let text = try decode(data)
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}\r")) }
        let delimiter = try tableDelimiter(lines)
        let rows = try lines.map { try fields($0, delimiter: delimiter) }
        guard rows.count > 1 else { throw WindogError.invalid("Text data file is empty or has no records") }
        var header: Int?
        for i in 0..<(rows.count - 1) where rows[i].count >= 2 {
            if timestamp(rows[i + 1].first ?? "") != nil {
                header = i
                break
            }
        }
        guard let header else { throw WindogError.invalid("Could not find a timestamp/header row in text data file") }
        let headings = rows[header]
        var records: [(Date, [String])] = []
        for row in rows.dropFirst(header + 1) {
            if let date = timestamp(row.first ?? "") { records.append((date, row)) }
        }
        guard let first = records.first else { throw WindogError.invalid("Text data file contains no parseable records") }
        let deltas = zip(records, records.dropFirst()).map { $1.0.timeIntervalSince($0.0) }
        guard deltas.allSatisfy({ $0 > 0 }) else {
            throw WindogError.invalid("Text timestamps must be increasing and unique; duplicate or reversed timestamps were found")
        }
        // The smallest interval establishes the grid. Gaps become missing rows,
        // never shifted observations. Non-grid timestamps are rejected explicitly.
        let seconds = deltas.min() ?? 3600
        guard seconds >= 60, abs(seconds / 60 - (seconds / 60).rounded()) < 1e-8 else {
            throw WindogError.unsupported("Text timestamps require a whole-minute time step")
        }
        var indices: [Int] = []
        for record in records {
            let offset = record.0.timeIntervalSince(first.0) / seconds
            guard abs(offset - offset.rounded()) < 1e-7, offset < 10_000_000 else {
                throw WindogError.unsupported("Irregular text timestamps do not fit a common minute grid")
            }
            indices.append(Int(offset.rounded()))
        }
        let count = (indices.last ?? 0) + 1
        let sensors = sensorMetadata(Array(rows.prefix(header)))
        var columns: [WindExportColumn] = []
        var usedIDs = Set<String>()
        for c in 1..<headings.count {
            let raw = headings[c].trimmingCharacters(in: .whitespaces)
            var label = replacing(replacing(raw, #"\s*\[[^\]]+\]\s*$"#, ""), #"\s+\[[^\]]*$"#, "").trimmingCharacters(in: .whitespaces)
            if label.isEmpty { label = "Column \(c)" }
            var unit = inferUnit(raw)
            var height = inferredHeight(label)
            var subtype = WindColumnMetadata.subtype(in: label)
            if let matches = captures(label, #"(?i)^CH(\d+)(Avg|SD|Max|Min)$"#), let number = Int(matches[0]) {
                let sensor = sensors[number] ?? [:]
                let suffix = matches[1].lowercased()
                subtype = ["avg":"Mean", "sd":"Std. dev.", "max":"Max", "min":"Min"][suffix] ?? "Mean"
                let description = sensor["description"] ?? "CH\(number)"
                label = subtype == "Mean" ? description : "\(description) \(subtype)"
                unit = sensor["units"].map(normalizeUnit) ?? unit
                height = sensor["height"].flatMap(firstNumber) ?? height
            }
            var values = Array<Double?>(repeating: nil, count: count)
            for (r, record) in records.enumerated() where c < record.1.count { values[indices[r]] = number(record.1[c]) }
            // Keep named empty columns: they can be configured and remain aligned.
            let baseID = label
            var id = baseID
            var suffix = 2
            while usedIDs.contains(id) { id = "\(baseID) (\(suffix))"; suffix += 1 }
            usedIDs.insert(id)
            columns.append(WindExportColumn(id: id, label: label, unit: unit, values: values, height: height,
                                            kind: WindColumnMetadata.kind(label: label, unit: unit), subtype: subtype))
        }
        guard !columns.isEmpty else { throw WindogError.invalid("Text data file contains no data columns") }
        var metadata = WindSummaryMetadata()
        for row in rows.prefix(min(header, 80)) {
            let line = row.joined(separator: " ")
            let lower = line.lowercased()
            guard let value = firstNumber(line) else { continue }
            if lower.contains("latitude") { metadata.latitude = value }
            if lower.contains("longitude") { metadata.longitude = value }
            if lower.contains("elevation") { metadata.elevation = value }
            if lower.contains("calm threshold") { metadata.calmThreshold = value }
        }
        let result = WindExportDataSet(name: name, startDate: first.0, timeStepMinutes: Int(seconds / 60), columns: columns, metadata: metadata)
        try result.validate()
        return result
    }

    private static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xff, 0xfe]), let text = String(data: data, encoding: .utf16LittleEndian) { return text }
        if data.starts(with: [0xfe, 0xff]), let text = String(data: data, encoding: .utf16BigEndian) { return text }
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") { return text }
        // Legacy Windographer text uses single-byte degree/superscript symbols.
        // Do not mistake this ASCII + unit-symbol export for GB18030 text.
        if data.allSatisfy({ $0 < 0x80 || [0xb0, 0xb2, 0xb3, 0xb5].contains($0) }),
           let text = String(data: data, encoding: .windowsCP1252) { return text }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for encoding in [gb, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
            if let text = String(data: data, encoding: encoding), text.contains("\n"), !text.contains("\0") { return text }
        }
        throw WindogError.invalid("Could not decode text file (UTF-8, UTF-16 or GB18030)")
    }

    private static func tableDelimiter(_ lines: [String]) throws -> Character {
        // Choose once from a real timestamp record, rather than header text,
        // where sensor names often contain many semicolons or quoted commas.
        let candidates: [Character] = ["\t", ",", ";"]
        for line in lines {
            var best: (Character, Int)?
            for delimiter in candidates {
                guard let row = try? fields(line, delimiter: delimiter), row.count > 1,
                      timestamp(row[0]) != nil else { continue }
                if row.count > (best?.1 ?? 0) { best = (delimiter, row.count) }
            }
            if let best { return best.0 }
        }
        throw WindogError.invalid("Could not find delimited timestamp records in text data file")
    }

    private static func fields(_ line: String, delimiter: Character) throws -> [String] {
        var result: [String] = [], field = "", quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if char == delimiter && !quoted { result.append(field); field = "" }
            else { field.append(char) }
            i += 1
        }
        guard !quoted else { throw WindogError.invalid("Unclosed quoted field in text data") }
        result.append(field)
        return result
    }

    private static let dateExpression = try! NSRegularExpression(pattern: #"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})[T\s]+(\d{1,2}):(\d{2})(?::(\d{2}))?$|^(\d{4})(\d{2})(\d{2})\s*(\d{2}):?(\d{2})$|^(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?$"#)
    private static func timestamp(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = text as NSString
        guard let match = dateExpression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func integer(_ index: Int) -> Int? { let range = match.range(at: index); return range.location == NSNotFound ? nil : Int(ns.substring(with: range)) }
        var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
        if let value = integer(1) { year = value; month = integer(2)!; day = integer(3)!; hour = integer(4)!; minute = integer(5)!; second = integer(6) ?? 0 }
        else if let value = integer(7) { year = value; month = integer(8)!; day = integer(9)!; hour = integer(10)!; minute = integer(11)!; second = 0 }
        else { year = integer(14)!; month = integer(12)!; day = integer(13)!; hour = integer(15)!; minute = integer(16)!; second = integer(17) ?? 0; if month > 12 { swap(&month, &day) } }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: date) == components else { return nil }
        return date
    }

    private static func sensorMetadata(_ rows: [[String]]) -> [Int: [String: String]] {
        var sensors: [Int: [String: String]] = [:], current: Int?
        for row in rows where row.count >= 2 {
            let key = row[0].trimmingCharacters(in: .whitespaces).lowercased(), value = row[1].trimmingCharacters(in: .whitespaces)
            if key == "channel #" { current = firstNumber(value).map(Int.init); if let current { sensors[current] = [:] } }
            else if let current { sensors[current, default: [:]][key] = value }
        }
        return sensors
    }
    private static func inferredHeight(_ label: String) -> Double? {
        if let height = WindColumnMetadata.height(in: label) { return height }
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(?<![a-z0-9])\d+(?:\.\d+)?(?![a-z0-9])"#) else { return nil }
        let ns = label as NSString
        return regex.matches(in: label, range: NSRange(location: 0, length: ns.length)).compactMap { match -> Double? in
            let prefix = ns.substring(to: match.range.location).lowercased().trimmingCharacters(in: .whitespaces)
            guard !prefix.hasSuffix("class"), !prefix.hasSuffix("channel"), !prefix.hasSuffix("ch") else { return nil }
            return Double(ns.substring(with: match.range))
        }.last
    }
    private static func number(_ value: String) -> Double? {
        let cleaned = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let number = Double(cleaned), number.isFinite, ![9999, -9999, -99999, -999999].contains(number) else { return nil }
        return number
    }
    private static func firstNumber(_ value: String) -> Double? { captures(value, #"([-+]?\d+(?:\.\d+)?)"#)?.first.flatMap(Double.init) }
    private static func captures(_ value: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let ns = value as NSString
        return (1..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
    }
    private static func replacing(_ value: String, _ pattern: String, _ replacement: String) -> String { value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
    private static func inferUnit(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.range(of: #"^(?:wd|winddir)(?:[_\s\d-]|$)"#, options: .regularExpression) != nil { return "deg" }
        if lower.range(of: #"^ta(?:[_\s\d-]|$)"#, options: .regularExpression) != nil { return "C" }
        if lower.range(of: #"^rh(?:[_\s\d-]|$)"#, options: .regularExpression) != nil { return "%RH" }
        if lower.contains("quality") || lower.contains("reliability") || label.contains("质量") || label.contains("可靠") { return "%" }
        if lower.contains("humidity") || label.contains("湿度") { return "%RH" }
        if lower.contains("m/s") || label.contains("风速") { return "m/s" }
        if lower.contains("direction") || label.contains("风向") { return "deg" }
        if lower.contains("temperature") || lower.contains("temp") || label.contains("温度") { return "C" }
        return normalizeUnit(captures(label, #"\[([^\]]+)\]"#)?.first ?? "")
    }
    private static func normalizeUnit(_ raw: String) -> String {
        let unit = raw.trimmingCharacters(in: .whitespaces), lower = raw.lowercased()
        if lower.contains("m/s") || lower.contains("ms-1") { return "m/s" }
        if lower.contains("w/m") { return "W/m2" }
        if lower.contains("deg") || unit == "°" { return "deg" }
        if lower.contains("kpa") { return "kPa" }
        if lower.contains("hpa") { return "hPa" }
        if ["c", "deg c", "degc", "℃", "°c"].contains(lower) { return "C" }
        if lower.contains("%rh") { return "%RH" }
        return unit
    }
}
