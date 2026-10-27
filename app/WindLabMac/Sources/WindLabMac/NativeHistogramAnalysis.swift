import Foundation
import WindogCore

struct HistogramCurvePoint: Sendable {
    let x: Double
    let frequency: Double
}

struct HistogramPresentation: Sendable {
    let result: HistogramResult
    let primaryLabel: String
    let primaryUnit: String
    let secondaryLabel: String
    let secondaryUnit: String
    let grouping: HistogramGrouping
    let curve: [HistogramCurvePoint]
    let fitLabel: String?

    /// Native grouped graphs are conditional; grouped tables are joint.
    func value(row: Int, group: Int, frequency: Bool, table: Bool) -> Double {
        let count = Double(result.counts[row][group])
        guard frequency else { return count }
        let denominator = !table && (grouping == .month || grouping == .hour)
            ? result.groupTotals[group] : (grouping == .column ? result.sampleCount : result.includedCount)
        return denominator > 0 ? count * 100 / Double(denominator) : 0
    }

    func normalization(frequency: Bool, table: Bool) -> String {
        guard frequency else { return "Occurrences" }
        if !table && grouping == .month { return "Frequency within each month (%)" }
        if !table && grouping == .hour { return "Frequency within each hour (%)" }
        return grouping == .single ? "Frequency (%)" : "Joint frequency (% of all valid records)"
    }

    func tableText(frequency: Bool, delimiter: String = "\t") -> String {
        func quote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = [["Primary bin lower [\(primaryUnit)]", "Primary bin upper [\(primaryUnit)]"]
                    + result.groups.map { $0.label + (frequency ? " (%)" : " (occurrences)") }]
        for index in result.bins.indices {
            let bin = result.bins[index]
            rows.append([Self.number(bin.lower), Self.number(bin.upper)] + result.groups.indices.map {
                Self.number(value(row: index, group: $0, frequency: frequency, table: true), digits: frequency ? 6 : 0)
            })
        }
        return rows.map { $0.map(quote).joined(separator: delimiter) }.joined(separator: "\r\n") + "\r\n"
    }

    static func number(_ value: Double, digits: Int? = nil) -> String {
        if let digits { return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value) }
        return String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

enum NativeHistogramAnalysis {
    static func build(dataset: WindExportDataSet, request: HistogramRequest) throws -> HistogramPresentation {
        let result = try HistogramAnalysis.analyze(dataset, request: request)
        let primary = dataset.columns.first { $0.id == request.primaryID }!
        let secondary = dataset.columns.first { $0.id == request.secondaryID }
        let kind = primary.kind ?? WindColumnMetadata.kind(label: primary.label, unit: primary.unit)
        let subtype = primary.subtype ?? WindColumnMetadata.subtype(in: primary.label)
        let fit = request.grouping == .single && kind == "wind_speed" && primary.unit == "m/s" && subtype == "Mean"
            ? WeibullAnalysis.maximumLikelihood(result.primaryValues) : nil
        let width = result.bins.first?.width ?? 0.5
        let lower = result.bins.first?.lower ?? 0
        let upper = result.bins.last?.upper ?? 1
        let curve: [HistogramCurvePoint] = fit.map { parameters in
            (0..<200).map { index in
                let x = lower + (upper - lower) * (Double(index) + 0.5) / 200
                return HistogramCurvePoint(x: x, frequency: parameters.density(x) * width * 100)
            }
        } ?? []
        let label = fit.map { String(format: "Weibull MLE: k=%.3f, c=%.3f m/s", $0.shape, $0.scale) }
        return HistogramPresentation(result: result, primaryLabel: primary.label, primaryUnit: primary.unit,
                                     secondaryLabel: secondary?.label ?? "", secondaryUnit: secondary?.unit ?? "",
                                     grouping: request.grouping, curve: curve, fitLabel: label)
    }
}

extension NativeHistogramAnalysis {
    static func legacySelection(filterMode: String, year: String, month: String, rangeStart: String, rangeEnd: String,
                                filterColumn: String, filterMin: String, filterMax: String) throws -> HistogramSelection {
        func number(_ text: String) throws -> Double? {
            if text == "-" { return nil }
            guard let value = Double(text), value.isFinite else { throw WindogError.invalid("Invalid filter value") }
            return value
        }
        func date(_ text: String) throws -> Date? {
            if text == "-" { return nil }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let value = formatter.date(from: text) else { throw WindogError.invalid("Invalid filter date") }
            return value
        }
        var result = HistogramSelection()
        switch filterMode {
        case "date": result.year = Int(year); result.month = Int(month)
        case "range":
            result.startDate = try date(rangeStart)
            result.endDate = try date(rangeEnd)?.addingTimeInterval(86400)
        case "column":
            if filterColumn != "-" { result.columnID = filterColumn; result.minimum = try number(filterMin); result.maximum = try number(filterMax) }
        case "none": break
        default: throw WindogError.invalid("Unknown filter mode")
        }
        return result
    }
}
