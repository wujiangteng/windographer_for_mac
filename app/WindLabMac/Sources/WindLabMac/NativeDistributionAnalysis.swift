import Foundation
import WindogCore

enum NativeDistributionAnalysis {
    static func result(fileURL: URL, primaryID: String, width: String, start: String, halfFirstBin: Bool,
                       filterMode: String, year: String, month: String, rangeStart: String, rangeEnd: String,
                       filterColumn: String, filterMin: String, filterMax: String) throws -> WindDistributionResult {
        let dataset = try WindogParser.exportDataSet(fileURL: fileURL)
        var selection = WindSampleSelection()
        switch filterMode {
        case "date":
            selection.year = try optionalInteger(year, label: "year")
            selection.month = try optionalInteger(month, label: "month")
        case "range":
            selection.startDate = try date(rangeStart)
            if let last = try date(rangeEnd) { selection.endDate = last.addingTimeInterval(86400) }
        case "column":
            if filterColumn != "-" {
                selection.columnID = filterColumn
                selection.minimum = try optionalNumber(filterMin, label: "filter minimum")
                selection.maximum = try optionalNumber(filterMax, label: "filter maximum")
            }
        case "none": break
        default: throw WindogError.unsupported("distribution filter mode")
        }
        let values = try selection.values(in: dataset, speedID: primaryID)
        return try WeibullAnalysis.analyze(values, binWidth: optionalNumber(width, label: "bin width"),
                                           binStart: optionalNumber(start, label: "bin start"), halfFirstBin: halfFirstBin)
    }

    static func analysis(_ result: WindDistributionResult) -> DecodedDistributionAnalysis {
        let nominalWidth = result.bins.last?.width ?? 0.5
        let maximum = result.bins.last?.upper ?? 1
        let bars = result.bins.map { DecodedHistogramBar(x: $0.center, y: $0.percentage, width: $0.width) }
        var rows: [DecodedDistributionRow] = []
        var curves: [DecodedSeries] = []
        for item in result.fits {
            let color: String = switch item.method {
            case .maximumLikelihood: "red"
            case .leastSquares: "yellow"
            case .wasp: "primary"
            }
            let fit = item.parameters
            let points: [DecodedPoint] = fit.map { parameters in
                (0..<100).map { index in
                    let x = maximum * (Double(index) + 0.5) / 100
                    return DecodedPoint(x: x, y: parameters.density(x) * nominalWidth * 100)
                }
            } ?? []
            curves.append(DecodedSeries(name: item.method.rawValue, colorName: color, points: points))
            rows.append(DecodedDistributionRow(
                algorithm: item.method.rawValue,
                k: number(fit?.shape, digits: 3), c: number(fit?.scale, digits: 3),
                mean: number(fit?.mean, digits: 3), proportionAbove: number(fit?.survival(result.mean), digits: 3),
                powerDensity: number(fit.map { 0.5 * result.airDensity * $0.thirdMoment }, digits: 1),
                rSquared: number(item.rSquared, digits: 5)))
        }
        curves.append(DecodedSeries(name: "Actual data", colorName: "green2", points: []))
        let countFormatter = NumberFormatter()
        countFormatter.locale = Locale(identifier: "en_US_POSIX")
        countFormatter.numberStyle = .decimal
        countFormatter.usesGroupingSeparator = true
        countFormatter.groupingSeparator = ","
        countFormatter.groupingSize = 3
        countFormatter.maximumFractionDigits = 0
        let count = countFormatter.string(from: NSNumber(value: result.sampleCount)) ?? String(result.sampleCount)
        rows.append(DecodedDistributionRow(algorithm: "Actual data (\(count) time steps)", k: "", c: "",
                                           mean: number(result.mean, digits: 3),
                                           proportionAbove: number(result.proportionAboveMean, digits: 3),
                                           powerDensity: number(result.powerDensity, digits: 1), rSquared: ""))
        return DecodedDistributionAnalysis(bars: bars, curves: curves, rows: rows,
                                           xLabel: "Wind Speed (m/s)", yLabel: "Frequency (%)",
                                           thresholdLabel: "\(number(result.mean, digits: 3)) m/s")
    }

    private static func number(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }

    private static func optionalNumber(_ value: String, label: String) throws -> Double? {
        if value == "-" { return nil }
        guard let number = Double(value), number.isFinite else { throw WindogError.invalid("invalid \(label)") }
        return number
    }

    private static func optionalInteger(_ value: String, label: String) throws -> Int? {
        if value == "-" { return nil }
        guard let number = Int(value) else { throw WindogError.invalid("invalid \(label)") }
        return number
    }

    private static func date(_ value: String) throws -> Date? {
        if value == "-" { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { throw WindogError.invalid("invalid date") }
        return date
    }
}
