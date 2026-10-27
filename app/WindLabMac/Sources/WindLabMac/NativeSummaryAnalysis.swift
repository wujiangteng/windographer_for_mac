import Foundation
import WindogCore

/// One raw-data calculation supplies both Summary text and chart coordinates.
enum NativeSummaryAnalysis {
    static func build(dataset source: WindExportDataSet, configuration: DataSetConfiguration = .empty,
                      fileName: String? = nil) throws -> WindogSummary {
        let dataset = try ConfigurationEditing.apply(source, configuration, visibleOnly: true)
        let metadata = dataset.metadata
        let result = try SummaryStatistics.analyze(dataset)
        func number(_ value: Double?, _ digits: Int = 3, _ suffix: String = "") -> String {
            guard let value, value.isFinite else { return "n/a" }
            return String(format: "%.*f", digits, value) + suffix
        }
        func coordinate(_ value: Double?, positive: String, negative: String) -> String {
            guard let value else { return "n/a" }
            return "\(value < 0 ? negative : positive) " + number(abs(value), 6)
        }
        func section(_ title: String, _ rows: [(String, String)]) -> DecodedPropertySection {
            DecodedPropertySection(title: title, rows: rows.map { DecodedPropertyRow(label: $0.0, value: $0.1) })
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyy/M/d HH:mm"
        let highest = result.columns.first { $0.id == result.highestSpeedColumnID }
        let height = highest?.height.map { String(format: "%g m", $0) } ?? "highest sensor"
        let sections = [
            section("Data set properties", [
                ("Latitude:", coordinate(metadata?.latitude, positive: "N", negative: "S")),
                ("Longitude:", coordinate(metadata?.longitude, positive: "E", negative: "W")),
                ("Elevation:", number(metadata?.elevation, 0, " m")),
                ("Start date:", date.string(from: result.startDate)),
                ("Last sample:", date.string(from: result.endDate)),
                ("Coverage:", number(Double(result.rowCount * dataset.timeStepMinutes) / 1440, 2, " days")),
                ("Time step:", "\(dataset.timeStepMinutes) minutes"),
                ("Stored data points:", result.storedValueCount.formatted()),
                ("Calm threshold:", metadata?.calmThreshold == nil ? "0 m/s (assumed)" : number(metadata?.calmThreshold, 2, " m/s"))]),
            section("Environmental conditions", [
                (result.temperature != nil && !result.columns.contains(where: { $0.kind == "temperature" && $0.mean != nil }) ? "Assumed temperature:" : "Mean temperature:", number(result.temperature, 1, " °C")),
                (result.pressure != nil && !result.columns.contains(where: { $0.kind == "pressure" && $0.mean != nil }) ? "Assumed pressure:" : "Mean pressure:", number(result.pressure, 1, " kPa")),
                ("Mean air density:", number(result.density, 3, " kg/m³")),
                ("Air density ratio:", number(result.densityRatio))]),
            section("Wind speed and power", [
                ("MoMM at \(height):", number(result.meanAtHighestHeight, 3, " m/s")),
                ("MoMM WPD (50m):", number(result.powerDensityAt50, 0, " W/m²")),
                ("Wind power class:", result.powerClass.map(String.init) ?? "n/a")]),
            section("Wind shear coefficients", [
                ("Power law exponent:", number(result.shear.powerExponent)),
                ("Surface roughness:", number(result.shear.roughnessLength, 5, " m")),
                ("Roughness class:", number(result.shear.roughnessClass, 2))]),
            section("Analysis scope", [
                ("MoMM weights:", "Month coverage"),
                ("Shear samples:", "Concurrent valid"),
                ("Missing metadata:", "n/a"),
                ("Quality flags:", "Not filtered"),
                ("Sensor metadata:", "Label / config")])
        ]
        func shearSeries(_ name: String, _ color: String, _ points: [WindShearPoint]) -> DecodedSeries {
            DecodedSeries(name: name, colorName: color, points: points.map { DecodedPoint(x: $0.speed, y: $0.height) })
        }
        let speed = result.columns.filter { $0.kind == "wind_speed" && $0.unit == "m/s" && $0.subtype == "Mean" }
        func periodSeries(_ column: WindColumnStatistics, _ periods: [WindPeriodMean]) -> DecodedSeries {
            DecodedSeries(name: column.label, colorName: column.colorName,
                          points: periods.map { DecodedPoint(x: Double($0.index), y: $0.mean ?? .nan) })
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        date.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let start = date.string(from: result.startDate)
        let end = date.string(from: result.coverageEndDate)
        var month = calendar.date(from: calendar.dateComponents([.year, .month], from: result.startDate))!
        date.dateFormat = "MMM"
        var labels: [DecodedTimeAxisLabel] = []
        while month <= result.coverageEndDate {
            if month >= result.startDate {
                labels.append(DecodedTimeAxisLabel(x: month.timeIntervalSince(result.startDate) / 86400, label: date.string(from: month)))
            }
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        let charts = DecodedCharts(
            shear: DecodedLineChart(series: [shearSeries("Measured data", "measured", result.shear.measured),
                                            shearSeries("Power law fit", "power", result.shear.powerCurve),
                                            shearSeries("Log law fit", "log", result.shear.logCurve)]),
            rose: DecodedRoseChart(series: result.roses.map { rose in
                DecodedPolarSeries(name: rose.label, colorName: rose.colorName,
                                   points: rose.points.map { DecodedPolarPoint(degrees: $0.degrees, radius: $0.fraction) })
            }),
            monthly: DecodedLineChart(series: speed.map { periodSeries($0, $0.monthly) }),
            diurnal: DecodedLineChart(series: speed.map { periodSeries($0, $0.hourly) }),
            timeSeries: DecodedTimeSeries(series: [], channels: result.columns.map {
                DecodedTimeSeriesChannel(id: $0.id, name: $0.label, colorName: $0.colorName,
                                         defaultVisible: $0.kind == "wind_speed" && $0.subtype == "Mean",
                                         unit: $0.unit, kind: $0.kind)
            }, monthLabels: labels, startDate: start, endDate: end,
            years: Array(calendar.component(.year, from: result.startDate)...calendar.component(.year, from: result.endDate))))
        return WindogSummary(fileName: fileName ?? source.name, sections: sections, charts: charts,
                             configuration: nil, sourceData: source, analysisData: dataset)
    }
}
