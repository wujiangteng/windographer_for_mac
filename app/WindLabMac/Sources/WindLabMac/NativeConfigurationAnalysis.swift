import Foundation
import WindogCore

/// Configuration and all three previews share the complete stored samples.
/// No display decimation is allowed before statistics are calculated.
enum NativeConfigurationAnalysis {
    static func configuration(dataset: WindExportDataSet, fileName: String? = nil) -> DecodedDataSetConfiguration {
        let colors = ["blue2", "blue3", "blue4", "blue5", "blue6", "blue7", "blue8", "measured", "green2", "brown", "orange", "violet", "red", "yellow"]
        let columns = dataset.columns.enumerated().map { index, column in
            let kind = column.kind ?? WindColumnMetadata.kind(label: column.label, unit: column.unit)
            let subtype = column.subtype ?? WindColumnMetadata.subtype(in: column.label)
            let stats = statistics(column: column)
            return DecodedDataColumnConfiguration(id: column.id, label: column.label, unit: column.unit,
                type: type(kind), subtype: subtype, colorName: column.colorName ?? colors[index % colors.count],
                height: column.height ?? WindColumnMetadata.height(in: column.label), visible: true,
                mean: formatted(stats.mean), min: formatted(stats.minimum), max: formatted(stats.maximum),
                associated: associations(column, in: dataset), preview: emptyPreview)
        }
        let date = WindExportNumbers.dateFormatter()
        date.dateFormat = "yyyy/M/d HH:mm"
        let end = dataset.startDate.addingTimeInterval(Double(dataset.rowCount * dataset.timeStepMinutes) * 60)
        let information = DecodedDataSetInformation(name: dataset.name, description: "",
            latitude: dataset.metadata?.latitude ?? 0, longitude: dataset.metadata?.longitude ?? 0,
            elevation: dataset.metadata?.elevation ?? 0, start: date.string(from: dataset.startDate), end: date.string(from: end),
            duration: String(format: "%g days", Double(dataset.rowCount * dataset.timeStepMinutes) / 1440),
            timeStep: "\(dataset.timeStepMinutes) minutes", calmThreshold: dataset.metadata?.calmThreshold ?? 0,
            invalidValue: 9999, timestampsIndicate: "Start",
            metadataSource: "Swift reads all stored samples. Unrecovered native site fields remain unknown (editable defaults shown as zero); colors and companion columns are inferred from labels and heights. Zero-length definitions have no reconstructed values.")
        return DecodedDataSetConfiguration(columns: columns, dataSet: information)
    }

    static let emptyPreview = DecodedColumnPreview(pdf: [], diurnal: [], monthly: [])

    static func preview(dataset: WindExportDataSet, channelID: String) throws -> DecodedColumnPreview {
        guard let column = dataset.columns.first(where: { $0.id == channelID }) else {
            throw WindogError.invalid("configuration preview column is unavailable")
        }
        let samples = column.values.enumerated().compactMap { index, raw -> (Int, Double)? in
            guard let value = valid(raw, column: column) else { return nil }
            return (index, value)
        }
        guard !samples.isEmpty else { return emptyPreview }
        let values = samples.map(\.1)
        let bins = try HistogramAnalysis.makeBins(values: values, settings: HistogramBinSettings(), minimumCount: 15, maximumCount: 40)
        var counts = Array(repeating: 0, count: bins.count)
        for value in values {
            if let index = bins.firstIndex(where: { value >= $0.lower && value < $0.upper })
                ?? (value == bins.last?.upper ? bins.count - 1 : nil) { counts[index] += 1 }
        }
        let pdf = bins.enumerated().map { index, bin in
            DecodedHistogramBar(x: (bin.lower + bin.upper) / 2,
                                y: Double(counts[index]) * 100 / Double(values.count), width: bin.upper - bin.lower)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var hourly = Array(repeating: [Double](), count: 24)
        var monthly = Array(repeating: [Double](), count: 12)
        var dailyExtrema: [Date: (month: Int, minimum: Double, maximum: Double)] = [:]
        let interval = Double(dataset.timeStepMinutes) * 60
        for (index, value) in samples {
            let date = dataset.startDate.addingTimeInterval(Double(index) * interval)
            hourly[calendar.component(.hour, from: date)].append(value)
            let month = calendar.component(.month, from: date) - 1
            monthly[month].append(value)
            let day = calendar.startOfDay(for: date)
            let prior = dailyExtrema[day]
            dailyExtrema[day] = (month, min(prior?.minimum ?? value, value), max(prior?.maximum ?? value, value))
        }
        let diurnal = hourly.enumerated().compactMap { hour, values -> DecodedPoint? in
            guard !values.isEmpty else { return nil }
            return DecodedPoint(x: Double(hour), y: mean(values))
        }
        let monthStats = monthly.enumerated().compactMap { month, values -> DecodedMonthlyStatistic? in
            guard !values.isEmpty else { return nil }
            let days = dailyExtrema.values.filter { $0.month == month }
            // Legacy field names q1/q3 are retained for view compatibility.
            // Native CTableBoxplot uses means of daily extrema, not quartiles.
            return DecodedMonthlyStatistic(x: Double(month), min: values.min()!, q1: mean(days.map(\.minimum)),
                mean: mean(values), q3: mean(days.map(\.maximum)), max: values.max()!)
        }
        return DecodedColumnPreview(pdf: pdf, diurnal: diurnal, monthly: monthStats)
    }

    static func statistics(column: WindExportColumn) -> (mean: Double?, minimum: Double?, maximum: Double?) {
        let values = column.values.compactMap { valid($0, column: column) }
        guard !values.isEmpty else { return (nil, nil, nil) }
        return (mean(values), values.min(), values.max())
    }

    static func formatted(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: abs(value) >= 100 ? "%.0f" : abs(value) >= 10 ? "%.1f" : "%.2f", value)
    }

    private static func valid(_ raw: Double?, column: WindExportColumn) -> Double? {
        guard let value = raw, value.isFinite, ![9999.0, -9999, -999999].contains(value) else { return nil }
        // Configuration is a raw stored-value inspector, not a quality filter:
        // negative observations remain visible for correcting their type/units.
        return value
    }
    // The configuration preview calls 0x50bc40 through 0x50bcf0 even for
    // direction columns; its direction flag changes SD, not this mean.
    private static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
    private static func type(_ kind: String) -> String {
        ["wind_speed": "Wind Speed", "wind_speed_synthesized": "Wind Speed", "wind_direction": "Wind Direction",
         "vertical_wind_speed": "Vert. Wind Speed", "temperature": "Temperature", "pressure": "Air Pressure",
         "humidity": "Relative Humidity", "turbine_output": "Wind Turbine Output", "turbulence_intensity": "Turbulence Intensity",
         "density": "Air Density", "power_density": "Wind Power Density", "quality": "Quality"][kind] ?? "Other"
    }
    private static func associations(_ column: WindExportColumn, in dataset: WindExportDataSet) -> DecodedAssociatedColumns {
        let kind = column.kind ?? WindColumnMetadata.kind(label: column.label, unit: column.unit)
        let base = sensorStem(column.label)
        func companion(_ subtype: String) -> String {
            let candidates = dataset.columns.filter { other in
                other.id != column.id && (other.kind ?? WindColumnMetadata.kind(label: other.label, unit: other.unit)) == kind
                    && (other.subtype ?? WindColumnMetadata.subtype(in: other.label)) == subtype
                    && other.height == column.height && other.unit == column.unit
            }
            return candidates.first { sensorStem($0.label) == base }?.id ?? (kind != "other" && candidates.count == 1 ? candidates[0].id : "<none>")
        }
        return DecodedAssociatedColumns(stdDev: companion("Std. dev."), min: companion("Min"), max: companion("Max"),
            speed: column.associatedSpeedID ?? "<nearest in height>")
    }
    private static func sensorStem(_ label: String) -> String {
        label.lowercased().replacingOccurrences(of: #"(?:^|[\s_;])(avg|average|mean|max|min|sd|stddev|std)(?:$|[\s_;])"#,
            with: ";", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " ;_"))
    }
}
