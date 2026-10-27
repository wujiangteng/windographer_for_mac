import Foundation

public struct WindExportColumn: Decodable, Sendable {
    public let id: String
    public let label: String
    public let unit: String
    public let values: [Double?]
    public let height: Double?
    public let kind: String?
    public let subtype: String?
    public let colorName: String?
    public let associatedSpeedID: String?
    public let flagIntervals: [WindogFlagInterval]?

    public init(id: String, label: String, unit: String, values: [Double?], height: Double? = nil,
                kind: String? = nil, subtype: String? = nil, colorName: String? = nil, associatedSpeedID: String? = nil, flagIntervals: [WindogFlagInterval]? = nil) {
        self.id = id
        self.label = label
        self.unit = unit
        self.values = values
        self.height = height
        self.kind = kind
        self.subtype = subtype
        self.colorName = colorName
        self.associatedSpeedID = associatedSpeedID
        self.flagIntervals = flagIntervals
    }

    public var heading: String { unit.isEmpty ? label : "\(label) [\(unit)]" }
}

public struct WindExportDataSet: Decodable, Sendable {
    public let name: String
    /// UTC is used as a neutral representation of the file's wall-clock timestamps.
    public let startDate: Date
    public let timeStepMinutes: Int
    public let columns: [WindExportColumn]
    public let metadata: WindSummaryMetadata?
    public let flags: [WindogFlag]?
    public var rowCount: Int { columns.map { $0.values.count }.max() ?? 0 }

    public init(name: String, startDate: Date, timeStepMinutes: Int, columns: [WindExportColumn], metadata: WindSummaryMetadata? = nil, flags: [WindogFlag]? = nil) {
        self.name = name
        self.startDate = startDate
        self.timeStepMinutes = timeStepMinutes
        self.columns = columns
        self.metadata = metadata
        self.flags = flags
    }

    public func validate() throws {
        guard !columns.isEmpty, rowCount > 0, timeStepMinutes > 0, startDate.timeIntervalSince1970.isFinite,
              Set(columns.map(\.id)).count == columns.count else {
            throw WindogError.invalid("export requires unique columns, stored values and a positive time step")
        }
    }

    public func selecting(ids: Set<String>, start: Date? = nil, end: Date? = nil) throws -> WindExportDataSet {
        try validate()
        guard !ids.isEmpty, ids.isSubset(of: Set(columns.map(\.id))) else {
            throw WindogError.invalid("select at least one available data column")
        }
        let seconds = Double(timeStepMinutes) * 60
        let lower = start.map { ceil($0.timeIntervalSince(startDate) / seconds) } ?? 0
        let upper = end.map { floor($0.timeIntervalSince(startDate) / seconds) + 1 } ?? Double(rowCount)
        guard lower.isFinite, upper.isFinite, lower < upper else { throw WindogError.invalid("invalid export time range") }
        let first = Int(min(Double(rowCount), max(0, lower)))
        let last = Int(min(Double(rowCount), max(0, upper)))
        guard first < last else { throw WindogError.invalid("no records in the selected time range") }
        let selected = columns.filter { ids.contains($0.id) }.map { column in
            let begin = min(first, column.values.count)
            let finish = min(last, column.values.count)
            return WindExportColumn(id: column.id, label: column.label, unit: column.unit,
                                    values: Array(column.values[begin..<finish]), height: column.height,
                                    kind: column.kind, subtype: column.subtype, colorName: column.colorName,
                                    associatedSpeedID: column.associatedSpeedID, flagIntervals: column.flagIntervals?.compactMap { interval in
                                        let lower = max(first, interval.startIndex)
                                        let upper = min(last - 1, interval.endIndex)
                                        return lower <= upper ? WindogFlagInterval(flagID: interval.flagID, startIndex: lower - first, endIndex: upper - first) : nil
                                    })
        }
        let result = WindExportDataSet(name: name, startDate: startDate.addingTimeInterval(Double(first) * seconds),
                                       timeStepMinutes: timeStepMinutes, columns: selected, metadata: metadata, flags: flags)
        try result.validate()
        return result
    }
}

public enum WindExportFormat: String, CaseIterable, Sendable {
    case windographerText, csv, tsv, xlsx, waspTab

    public var title: String {
        switch self {
        case .windographerText: return "Windographer text (.txt)"
        case .csv: return "Comma-separated values (.csv)"
        case .tsv: return "Tab-separated values (.tsv)"
        case .xlsx: return "Excel workbook (.xlsx)"
        case .waspTab: return "WAsP frequency table (.tab)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .windographerText: return "txt"
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .xlsx: return "xlsx"
        case .waspTab: return "tab"
        }
    }
}

public enum WindExportNumbers {
    public static func string(_ value: Double) -> String {
        String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }
}
