import Foundation

public enum HistogramGrouping: String, CaseIterable, Sendable {
    case single, month, hour, column
}

public enum HistogramNormalization: String, CaseIterable, Sendable {
    case allSamples, withinGroup, withinPrimaryBin
}

public struct HistogramBinSettings: Sendable {
    public var width: Double?
    public var start: Double?
    public var halfFirst: Bool

    public init(width: Double? = nil, start: Double? = nil, halfFirst: Bool = false) {
        self.width = width
        self.start = start
        self.halfFirst = halfFirst
    }
}

public struct HistogramSelection: Sendable {
    public var year: Int?
    public var month: Int?
    public var startDate: Date?
    /// Exclusive upper boundary, including a date-only final day by passing its next midnight.
    public var endDate: Date?
    public var columnID: String?
    public var minimum: Double?
    public var maximum: Double?
    /// Optional caller-resolved source indices, for decoded flag/time interval selection.
    public var includedIndices: Set<Int>?

    public init(year: Int? = nil, month: Int? = nil, startDate: Date? = nil, endDate: Date? = nil,
                columnID: String? = nil, minimum: Double? = nil, maximum: Double? = nil,
                includedIndices: Set<Int>? = nil) {
        self.year = year
        self.month = month
        self.startDate = startDate
        self.endDate = endDate
        self.columnID = columnID
        self.minimum = minimum
        self.maximum = maximum
        self.includedIndices = includedIndices
    }
}

public struct HistogramRequest: Sendable {
    public var primaryID: String
    public var grouping: HistogramGrouping
    public var secondaryID: String?
    public var primaryBins: HistogramBinSettings
    public var secondaryBins: HistogramBinSettings
    public var selection: HistogramSelection
    public var normalization: HistogramNormalization

    public init(primaryID: String, grouping: HistogramGrouping = .single, secondaryID: String? = nil,
                primaryBins: HistogramBinSettings = .init(), secondaryBins: HistogramBinSettings = .init(),
                selection: HistogramSelection = .init(), normalization: HistogramNormalization = .allSamples) {
        self.primaryID = primaryID
        self.grouping = grouping
        self.secondaryID = secondaryID
        self.primaryBins = primaryBins
        self.secondaryBins = secondaryBins
        self.selection = selection
        self.normalization = normalization
    }
}

public struct HistogramBin: Sendable {
    public let lower: Double
    public let upper: Double
    public var center: Double { (lower + upper) / 2 }
    public var width: Double { upper - lower }
}

public struct HistogramGroup: Sendable {
    public let index: Int
    public let label: String
    public let lower: Double?
    public let upper: Double?
}

public struct HistogramResult: Sendable {
    public let bins: [HistogramBin]
    public var primaryBins: [HistogramBin] { bins }
    public let groups: [HistogramGroup]
    /// Primary-bin rows and secondary-group columns.
    public let counts: [[Int]]
    public let percentages: [[Double]]
    /// Valid samples after all selection and, for two columns, valid pairing.
    /// Displayed-bin truncation does not redefine the fitting sample.
    public let sampleCount: Int
    public var totalValidCount: Int { sampleCount }
    public let includedCount: Int
    public let primaryValues: [Double]
    /// Native percentage denominator: binned samples for one-dimensional
    /// modes, all concurrent valid pairs for the two-column mode.
    public let normalizationCount: Int
    public let groupTotals: [Int]
    /// Valid group members before primary-bin range truncation.
    public let rawGroupTotals: [Int]
}

/// Generic one- and two-dimensional frequency counting. The original stored
/// sample selection supplies both chart and table output, including empty bins.
public enum HistogramAnalysis {
    public static func analyze(_ dataset: WindExportDataSet, request: HistogramRequest) throws -> HistogramResult {
        try dataset.validate()
        let lookup = Dictionary(uniqueKeysWithValues: dataset.columns.map { ($0.id, $0) })
        guard let primary = lookup[request.primaryID] else {
            throw WindogError.invalid("histogram primary column is unavailable")
        }
        let secondary: WindExportColumn?
        if request.grouping == .column {
            guard let id = request.secondaryID, let column = lookup[id] else {
                throw WindogError.invalid("select an available secondary histogram column")
            }
            secondary = column
        } else { secondary = nil }
        let selection = request.selection
        try validate(selection)
        let filter: WindExportColumn?
        if let id = selection.columnID {
            guard let column = lookup[id] else { throw WindogError.invalid("histogram filter column is unavailable") }
            filter = column
        } else { filter = nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let interval = Double(dataset.timeStepMinutes) * 60
        struct Sample {
            let primary: Double
            let secondary: Double?
            let period: Int
        }
        var samples: [Sample] = []
        samples.reserveCapacity(primary.values.count)
        for index in primary.values.indices {
            if let indices = selection.includedIndices, !indices.contains(index) { continue }
            let date = dataset.startDate.addingTimeInterval(Double(index) * interval)
            if let start = selection.startDate, date < start { continue }
            if let end = selection.endDate, date >= end { continue }
            if let year = selection.year, calendar.component(.year, from: date) != year { continue }
            // The native month-comparison page replaces a selected month with
            // each of its twelve month filters, preserving year/range filters.
            if request.grouping != .month, let month = selection.month,
               calendar.component(.month, from: date) != month { continue }
            if let filter {
                guard index < filter.values.count, let value = valid(filter.values[index], column: filter) else { continue }
                if let minimum = selection.minimum, value < minimum { continue }
                if let maximum = selection.maximum, value > maximum { continue }
            }
            guard let value = valid(primary.values[index], column: primary) else { continue }
            let other: Double?
            if let secondary {
                guard index < secondary.values.count, let candidate = valid(secondary.values[index], column: secondary) else { continue }
                other = candidate
            } else { other = nil }
            let period: Int
            switch request.grouping {
            case .month: period = calendar.component(.month, from: date) - 1
            case .hour: period = calendar.component(.hour, from: date)
            default: period = 0
            }
            samples.append(Sample(primary: value, secondary: other, period: period))
        }
        guard !samples.isEmpty else { throw WindogError.invalid("no valid samples match the histogram selection") }
        let primaryValues = samples.map(\.primary)
        let bins = try makeBins(values: primaryValues, settings: request.primaryBins, twoDimensional: request.grouping == .column)
        let secondaryBins = try secondary.map { _ in
            try makeBins(values: samples.compactMap(\.secondary), settings: request.secondaryBins, twoDimensional: true)
        }
        let groups: [HistogramGroup]
        switch request.grouping {
        case .single:
            groups = [HistogramGroup(index: 0, label: "All data", lower: nil, upper: nil)]
        case .month:
            let labels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            groups = labels.enumerated().map { HistogramGroup(index: $0.offset, label: $0.element, lower: nil, upper: nil) }
        case .hour:
            groups = (0..<24).map { HistogramGroup(index: $0, label: String(format: "%02d:00", $0), lower: nil, upper: nil) }
        case .column:
            groups = (secondaryBins ?? []).enumerated().map {
                HistogramGroup(index: $0.offset, label: "\(format($0.element.lower)) – \(format($0.element.upper))",
                               lower: $0.element.lower, upper: $0.element.upper)
            }
        }
        guard bins.count * groups.count <= 1_000_000 else {
            throw WindogError.invalid("too many histogram cells; increase bin widths")
        }
        var counts = Array(repeating: Array(repeating: 0, count: groups.count), count: bins.count)
        var groupTotals = Array(repeating: 0, count: groups.count)
        for sample in samples {
            let group: Int?
            if let secondaryBins, let value = sample.secondary { group = index(of: value, in: secondaryBins) }
            else { group = sample.period }
            guard let group else { continue }
            groupTotals[group] += 1
            guard let row = index(of: sample.primary, in: bins) else { continue }
            counts[row][group] += 1
        }
        let includedCount = counts.reduce(0) { $0 + $1.reduce(0, +) }
        let rowTotals = counts.map { $0.reduce(0, +) }
        let rawGroupTotals = groupTotals
        if request.grouping != .column {
            groupTotals = groups.indices.map { group in counts.reduce(0) { $0 + $1[group] } }
        }
        let normalizationCount = request.grouping == .column ? samples.count : includedCount
        let percentages = counts.enumerated().map { row, values in
            values.enumerated().map { group, count -> Double in
                let denominator: Int
                switch request.normalization {
                case .allSamples: denominator = normalizationCount
                case .withinGroup: denominator = groupTotals[group]
                case .withinPrimaryBin: denominator = rowTotals[row]
                }
                return denominator > 0 ? Double(count) * 100 / Double(denominator) : 0
            }
        }
        return HistogramResult(bins: bins, groups: groups, counts: counts, percentages: percentages,
                               sampleCount: samples.count, includedCount: includedCount,
                               primaryValues: primaryValues, normalizationCount: normalizationCount,
                               groupTotals: groupTotals, rawGroupTotals: rawGroupTotals)
    }

    private static func validate(_ selection: HistogramSelection) throws {
        if let year = selection.year, !(1...9999).contains(year) { throw WindogError.invalid("invalid histogram year") }
        if let month = selection.month, !(1...12).contains(month) { throw WindogError.invalid("invalid histogram month") }
        if let start = selection.startDate, !start.timeIntervalSince1970.isFinite { throw WindogError.invalid("invalid histogram start date") }
        if let end = selection.endDate, !end.timeIntervalSince1970.isFinite { throw WindogError.invalid("invalid histogram end date") }
        if let start = selection.startDate, let end = selection.endDate, start >= end { throw WindogError.invalid("histogram date range is empty") }
        if let minimum = selection.minimum, !minimum.isFinite { throw WindogError.invalid("invalid histogram minimum") }
        if let maximum = selection.maximum, !maximum.isFinite { throw WindogError.invalid("invalid histogram maximum") }
        if let minimum = selection.minimum, let maximum = selection.maximum, minimum > maximum { throw WindogError.invalid("histogram minimum exceeds maximum") }
    }

    private static func valid(_ raw: Double?, column: WindExportColumn) -> Double? {
        guard let value = raw, value.isFinite, value != 9999, value != -9999, value != -999999 else { return nil }
        let kind = column.kind ?? WindColumnMetadata.kind(label: column.label, unit: column.unit)
        switch kind {
        case "wind_speed", "wind_speed_synthesized", "power_density": return value >= 0 ? value : nil
        case "wind_direction": return value >= 0 && value < 360.001 ? value : nil
        case "pressure", "density": return value > 0 ? value : nil
        case "temperature":
            let minimum = column.unit == "K" ? 0.0 : ["F", "°F"].contains(column.unit) ? -459.67 : -273.15
            return value >= minimum ? value : nil
        default: return value
        }
    }

    public static func makeBins(values: [Double], settings: HistogramBinSettings, twoDimensional: Bool = false,
                         minimumCount: Int? = nil, maximumCount: Int? = nil) throws -> [HistogramBin] {
        if let width = settings.width, !width.isFinite || width <= 0 { throw WindogError.invalid("histogram bin width must be positive") }
        if let start = settings.start, !start.isFinite { throw WindogError.invalid("histogram bin start must be finite") }
        let minimum = minimumCount ?? (twoDimensional ? 20 : 40)
        let maximum = maximumCount ?? (twoDimensional ? 50 : 80)
        let automatic = minimum == 40 && maximum == 80 ? WeibullAnalysis.automaticGrid(values)
            : automaticGrid(values, minimumCount: minimum, maximumCount: maximum)
        let span = Double(automatic.count) * automatic.width
        let width = settings.width.map { span / $0 <= 500.1 ? $0 : automatic.width } ?? automatic.width
        let start = settings.start ?? automatic.start
        let firstWidth = settings.halfFirst ? width / 2 : width
        let upper = max(start, automatic.start + Double(automatic.count) * automatic.width)
        let rawCount = max(1, 1 + ceil(max(0, upper - start - firstWidth) / width))
        guard rawCount.isFinite, rawCount <= 10_000 else { throw WindogError.invalid("too many histogram bins; increase the width") }
        return (0..<Int(rawCount)).map { index in
            let lower = index == 0 ? start : start + firstWidth + Double(index - 1) * width
            return HistogramBin(lower: lower, upper: lower + (index == 0 ? firstWidth : width))
        }
    }

    /// Same native nice-grid routine as the one-dimensional Weibull grid, with
    /// the 20–50 target count requested by the two-dimensional page.
    private static func automaticGrid(_ values: [Double], minimumCount: Int, maximumCount: Int) -> (start: Double, width: Double, count: Int) {
        guard let minimum = values.min(), let maximum = values.max() else { return (0, 0.05, minimumCount) }
        var lower = minimum
        var upper = maximum
        if nearlyEqual(lower, upper, tolerance: 0.0001) {
            if abs(lower) <= 0.0001 { upper = 1 }
            else if lower > 0 { upper = lower * 1.5; lower *= 0.5 }
            else { lower *= 1.5; upper *= 0.5 }
        }
        var steps = niceSteps(lower: lower, upper: upper)
        lower = floor(lower / steps.major) * steps.major
        if !multiple(upper, of: steps.major) { upper = (trunc(upper / steps.major) + 1) * steps.major }
        steps = niceSteps(lower: lower, upper: upper)
        if !multiple(lower, of: steps.major) { lower = floor(lower / steps.major) * steps.major }
        if !multiple(upper, of: steps.major) { upper = (trunc(upper / steps.major) + 1) * steps.major }
        let span = max(upper - lower, Double.leastNormalMagnitude)
        let countSteps = niceSteps(lower: lower, upper: upper)
        var count = Int((span / countSteps.minor).rounded(.toNearestOrAwayFromZero))
        if count < 1 { count = 4 }
        if count < minimumCount {
            while count < minimumCount { count *= 2 }
        } else if count > maximumCount {
            while count > maximumCount {
                if count % 2 != 0, count % 3 == 0 { count /= 3 }
                else if count % 2 != 0, count % 5 == 0 { count /= 5 }
                else { count /= 2 }
            }
        }
        if count < minimumCount || count > maximumCount {
            count = Int((span / countSteps.major).rounded(.toNearestOrAwayFromZero))
            if count < 1 { count = 4 }
            while count < minimumCount { count *= 2 }
            while count > maximumCount { count /= 2 }
            if count < minimumCount || count > maximumCount { count = minimumCount }
        }
        return (lower, span / Double(count), count)
    }

    private static func nearlyEqual(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
        if a == 0 { return abs(b) <= tolerance }
        if b == 0 { return abs(a) <= tolerance }
        return abs((a - b) / a) <= tolerance
    }

    private static func multiple(_ value: Double, of step: Double) -> Bool {
        nearlyEqual(value, (value / step).rounded(.toNearestOrAwayFromZero) * step, tolerance: 0.000001)
    }

    private static func niceSteps(lower: Double, upper: Double) -> (major: Double, minor: Double) {
        var span = upper - lower
        if span == 0 { span = 1 }
        let magnitude = pow(10, max(-15, floor(log10(abs(span)))))
        if lower >= 0, lower <= 1, upper >= 359, upper <= 360 { return (30, 10) }
        let quarter = 2.5 * span / magnitude
        if multiple(lower, of: 4), multiple(upper, of: 4), [3.0, 4, 6, 8].contains(quarter) {
            return (quarter * magnitude / 10, magnitude / 10)
        }
        let scaled = 2 * span / magnitude
        let primary: Double
        let secondary: Double
        if scaled < 3 { primary = 2; secondary = 1 }
        else if scaled == 3 { primary = 5; secondary = 1 }
        else if scaled < 4 { primary = 4; secondary = 1 }
        else if scaled < 7.5 { primary = 5; secondary = 1 }
        else if scaled < 15 { primary = 10; secondary = 5 }
        else { primary = 20; secondary = 5 }
        return (primary * magnitude / 10, secondary * magnitude / 10)
    }

    private static func index(of value: Double, in bins: [HistogramBin]) -> Int? {
        guard let first = bins.first, let last = bins.last, value >= first.lower, value <= last.upper else { return nil }
        if value == last.upper { return bins.count - 1 }
        var low = 0
        var high = bins.count
        while low < high {
            let middle = low + (high - low) / 2
            if value >= bins[middle].upper { low = middle + 1 }
            else { high = middle }
        }
        return low < bins.count ? low : nil
    }

    private static func format(_ value: Double) -> String { String(format: "%.6g", value) }
}
