import Foundation

public struct WindPeriodMean: Sendable {
    public let index: Int
    public let mean: Double?
    public let count: Int
}

public struct WindColumnStatistics: Sendable {
    public let id: String
    public let label: String
    public let unit: String
    public let kind: String
    public let subtype: String
    public let colorName: String
    public let height: Double?
    public let validCount: Int
    public let mean: Double?
    public let monthly: [WindPeriodMean]
    public let hourly: [WindPeriodMean]
    public let momm: Double?
}

public struct WindShearPoint: Sendable {
    public let height: Double
    public let speed: Double
}

public struct WindShearStatistics: Sendable {
    public let measured: [WindShearPoint]
    public let powerExponent: Double?
    public let roughnessLength: Double?
    public let roughnessClass: Double?
    public let powerCurve: [WindShearPoint]
    public let logCurve: [WindShearPoint]
}

public struct WindRoseFrequency: Sendable {
    public let degrees: Double
    public let fraction: Double
}

public struct WindFrequencyRose: Sendable {
    public let id: String
    public let label: String
    public let colorName: String
    public let points: [WindRoseFrequency]
    public let validCount: Int
    public let calmCount: Int
    public let associatedSpeedID: String?
}

public struct WindSummaryResult: Sendable {
    public let columns: [WindColumnStatistics]
    public let highestSpeedColumnID: String?
    public let meanAtHighestHeight: Double?
    public let shear: WindShearStatistics
    public let roses: [WindFrequencyRose]
    /// Fallback inferred from physical WPD columns and heights. The native speed
    /// association map (key 6) is not yet decoded, so its sensor selection may differ.
    public let powerDensityAt50: Double?
    public let powerClass: Int?
    public let temperature: Double?
    public let pressure: Double?
    public let density: Double?
    public let densityRatio: Double?
    public let startDate: Date
    /// Last actual sample timestamp, not the exclusive coverage boundary.
    public let endDate: Date
    public let coverageEndDate: Date
    public let rowCount: Int
    public let storedValueCount: Int
    public let validValueCount: Int
}

/// Summary statistics reconstructed from the inspected 4.0.24 routines. Native
/// code locations and unresolved metadata assumptions are recorded separately in
/// analysis/windographer-4.0.241-summary/. No environmental measurements are
/// fabricated when neither source values nor a known site elevation are present.
public enum SummaryStatistics {
    // February is stored as a 32-bit float in the native month-day table.
    private static let monthDays = [31.0, Double(Float(28.24)), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    private static let palette = ["accent", "brown", "violet", "secondary", "yellow", "green2", "red", "purple"]

    public static func analyze(_ dataset: WindExportDataSet, availabilityWeightedMoMM: Bool = true) throws -> WindSummaryResult {
        try dataset.validate()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let interval = Double(dataset.timeStepMinutes) * 60
        // Native 0x542d60 uses interval start plus a one-second numerical guard.
        let dates = (0..<dataset.rowCount).map { dataset.startDate.addingTimeInterval(Double($0) * interval + 1) }
        let months = dates.map { calendar.component(.month, from: $0) - 1 }
        let hours = dates.map { calendar.component(.hour, from: $0) }
        var stats: [WindColumnStatistics] = []
        for (position, column) in dataset.columns.enumerated() {
            let kind = kind(of: column)
            var sums = Array(repeating: 0.0, count: 12)
            var counts = Array(repeating: 0, count: 12)
            var hourSums = Array(repeating: 0.0, count: 24)
            var hourCounts = Array(repeating: 0, count: 24)
            var total = 0.0
            var validCount = 0
            for index in column.values.indices {
                guard let value = valid(column.values[index], kind: kind) else { continue }
                sums[months[index]] += value
                counts[months[index]] += 1
                hourSums[hours[index]] += value
                hourCounts[hours[index]] += 1
                total += value
                validCount += 1
            }
            let monthly = (0..<12).map { WindPeriodMean(index: $0, mean: counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil, count: counts[$0]) }
            let hourly = (0..<24).map { WindPeriodMean(index: $0, mean: hourCounts[$0] > 0 ? hourSums[$0] / Double(hourCounts[$0]) : nil, count: hourCounts[$0]) }
            var weightedSum = 0.0
            var weightSum = 0.0
            for index in 0..<12 {
                guard let mean = monthly[index].mean else { continue }
                let availability = min(1, Double(counts[index]) / (monthDays[index] * 1440 / Double(dataset.timeStepMinutes)))
                let factor = availabilityWeightedMoMM ? availability : (availability > 0.001 ? 1 : 0)
                let weight = monthDays[index] * factor
                weightedSum += mean * weight
                weightSum += weight
            }
            stats.append(WindColumnStatistics(id: column.id, label: column.label, unit: column.unit, kind: kind,
                                              subtype: column.subtype ?? WindColumnMetadata.subtype(in: column.label),
                                              colorName: column.colorName ?? palette[position % palette.count],
                                              height: column.height ?? WindColumnMetadata.height(in: column.label),
                                              validCount: validCount, mean: validCount > 0 ? total / Double(validCount) : nil,
                                              monthly: monthly, hourly: hourly, momm: weightSum > 0 ? weightedSum / weightSum : nil))
        }
        let speedStats = stats.filter { $0.kind == "wind_speed" && $0.unit == "m/s" && $0.subtype == "Mean" && $0.validCount > 0 }
        let highest = speedStats.sorted { ($0.height ?? -.infinity) > ($1.height ?? -.infinity) }.first
        let shear = shearStatistics(dataset: dataset, columns: speedStats)
        let roses = roseStatistics(dataset: dataset, statistics: stats, speeds: speedStats)
        let power = powerAt50(stats)
        let highestTemperature = highestColumn(stats, kind: "temperature")
        let highestPressure = highestColumn(stats, kind: "pressure")
        let fallbackElevation = dataset.metadata?.elevation.map {
            $0 + (highestTemperature?.height ?? highestPressure?.height ?? 0)
        }
        let temperature = highestTemperature?.mean.map { value -> Double in
            if highestTemperature?.unit == "K" { return value - 273.15 }
            if ["F", "°F"].contains(highestTemperature?.unit ?? "") { return (value - 32) * 5 / 9 }
            return value
        } ?? fallbackElevation.map { 15 - 0.0065 * $0 }
        let pressure = highestPressure?.mean.map { value -> Double in
            switch highestPressure?.unit {
            case "Pa": return value / 1000
            case "hPa", "mbar": return value / 10
            default: return value
            }
        } ?? fallbackElevation.flatMap { elevation -> Double? in
            let base = 1 - 0.0065 * elevation / 288.15
            return base > 0 ? 101.325 * pow(base, 5.258643627) : nil
        }
        let density = highestColumn(stats, kind: "density")?.mean
        return WindSummaryResult(columns: stats, highestSpeedColumnID: highest?.id, meanAtHighestHeight: highest?.momm,
                                 shear: shear, roses: roses, powerDensityAt50: power, powerClass: power.map(powerClass),
                                 temperature: temperature, pressure: pressure, density: density, densityRatio: density.map { $0 / 1.225 },
                                 startDate: dataset.startDate,
                                 endDate: dataset.startDate.addingTimeInterval(Double(dataset.rowCount - 1) * interval),
                                 coverageEndDate: dataset.startDate.addingTimeInterval(Double(dataset.rowCount) * interval),
                                 rowCount: dataset.rowCount, storedValueCount: dataset.columns.reduce(0) { $0 + $1.values.count },
                                 validValueCount: stats.reduce(0) { $0 + $1.validCount })
    }

    private static func kind(of column: WindExportColumn) -> String {
        let supplied = column.kind ?? WindColumnMetadata.kind(label: column.label, unit: column.unit)
        return supplied == "wind_speed_synthesized" ? "wind_speed" : supplied
    }

    private static func valid(_ input: Double?, kind: String) -> Double? {
        guard let value = input, value.isFinite, value != 9999, value != -9999 else { return nil }
        switch kind {
        case "temperature": return value >= -273.15 ? value : nil
        case "wind_direction": return value >= 0 && value < 360.001 ? value : nil
        case "wind_speed", "power_density": return value >= 0 ? value : nil
        case "pressure", "density": return value > 0 ? value : nil
        default: return value
        }
    }

    private static func highestColumn(_ columns: [WindColumnStatistics], kind: String) -> WindColumnStatistics? {
        columns.filter {
            guard $0.kind == kind, $0.subtype == "Mean", $0.mean != nil else { return false }
            switch kind {
            case "temperature": return ["C", "°C", "℃", "K", "F", "°F"].contains($0.unit)
            case "pressure": return ["kPa", "hPa", "Pa", "mbar"].contains($0.unit)
            case "density": return ["kg/m3", "kg/m³"].contains($0.unit)
            default: return true
            }
        }
            .sorted { ($0.height ?? -.infinity) > ($1.height ?? -.infinity) }.first
    }

    private static func regression(_ pairs: [(Double, Double)]) -> (intercept: Double, slope: Double)? {
        let pairs = pairs.filter { $0.0.isFinite && $0.1.isFinite }
        guard pairs.count >= 2 else { return nil }
        let x = pairs.reduce(0) { $0 + $1.0 } / Double(pairs.count)
        let y = pairs.reduce(0) { $0 + $1.1 } / Double(pairs.count)
        let variance = pairs.reduce(0) { $0 + pow($1.0 - x, 2) }
        guard variance > 1e-24 else { return nil }
        let slope = pairs.reduce(0) { $0 + ($1.0 - x) * ($1.1 - y) } / variance
        return (y - slope * x, slope)
    }

    private static func shearStatistics(dataset: WindExportDataSet, columns: [WindColumnStatistics]) -> WindShearStatistics {
        let eligible = columns.filter { ($0.height ?? 0) > 0 && $0.height!.isFinite }.sorted { $0.height! < $1.height! }
        let empty = WindShearStatistics(measured: [], powerExponent: nil, roughnessLength: nil, roughnessClass: nil, powerCurve: [], logCurve: [])
        guard Set(eligible.map { $0.height! }).count >= 2 else { return empty }
        let lookup = Dictionary(uniqueKeysWithValues: dataset.columns.map { ($0.id, $0) })
        let inputs = eligible.compactMap { lookup[$0.id] }
        let length = inputs.map { $0.values.count }.min() ?? 0
        var sums = Array(repeating: 0.0, count: inputs.count)
        var count = 0
        for index in 0..<length {
            let values = inputs.map { valid($0.values[index], kind: "wind_speed") }
            guard values.allSatisfy({ $0 != nil }) else { continue }
            for position in values.indices { sums[position] += values[position]! }
            count += 1
        }
        guard count > 0 else { return empty }
        let measured = eligible.enumerated().compactMap { position, column -> WindShearPoint? in
            let speed = sums[position] / Double(count)
            guard speed > 0 else { return nil }
            return WindShearPoint(height: column.height!, speed: speed)
        }
        let power = regression(measured.map { (log($0.height), log($0.speed)) })
        let logarithmic = regression(measured.map { (log($0.height), $0.speed) })
        let roughness = logarithmic.flatMap { fit -> Double? in
            guard fit.slope > 0 else { return nil }
            let value = exp(-fit.intercept / fit.slope)
            return value.isFinite && value > 0 ? value : nil
        }
        let maximum = measured.map(\.height).max() ?? 0
        let minimum = min(1, measured.map(\.height).min() ?? 1)
        let heights = (0...80).map { minimum + (maximum - minimum) * Double($0) / 80 }
        let powerCurve = power.map { fit in
            heights.compactMap { height -> WindShearPoint? in
                let speed = exp(fit.intercept + fit.slope * log(height))
                return speed.isFinite && speed >= 0 ? WindShearPoint(height: height, speed: speed) : nil
            }
        } ?? []
        let logCurve = logarithmic.flatMap { fit -> [WindShearPoint]? in
            guard fit.slope > 0 else { return nil }
            return heights.compactMap { height in
                let speed = fit.intercept + fit.slope * log(height)
                return speed.isFinite && speed >= 0 ? WindShearPoint(height: height, speed: speed) : nil
            }
        } ?? []
        return WindShearStatistics(measured: measured, powerExponent: power?.slope,
                                   roughnessLength: roughness, roughnessClass: roughness.map(roughnessClass),
                                   powerCurve: powerCurve, logCurve: logCurve)
    }

    public static func roughnessClass(_ length: Double) -> Double {
        guard length.isFinite, length > 0 else { return 0 }
        let result = length > 0.03 ? log(length) / log(3.3333333) + 3.912489289
            : log(length) / log(150) + 1.699823015
        return min(100, max(0, result))
    }

    private static func powerAt50(_ columns: [WindColumnStatistics]) -> Double? {
        let points = columns.filter {
            let knownUnit = ["W/m2", "W/m²", "W/m^2"].contains($0.unit)
            let inferredWithoutUnit = $0.unit.isEmpty && WindColumnMetadata.kind(label: $0.label, unit: "") == "power_density"
            return $0.kind == "power_density" && (knownUnit || inferredWithoutUnit) && $0.subtype == "Mean"
                && ($0.height ?? 0) > 0 && $0.height!.isFinite && ($0.momm ?? 0) > 0
        }
        if points.count == 1 {
            guard abs(points[0].height! - 50) / 50 <= 0.0001 else { return nil }
            return points[0].momm
        }
        guard let fit = regression(points.map { (log($0.height!), log($0.momm!)) }) else { return nil }
        let value = exp(fit.intercept + fit.slope * log(50))
        return value.isFinite && value >= 0 ? value : nil
    }

    private static func powerClass(_ value: Double) -> Int {
        let boundaries = [200.0, 300, 400, 500, 600, 800, 2000]
        return (boundaries.firstIndex { value < $0 } ?? boundaries.count) + 1
    }

    private static func roseStatistics(dataset: WindExportDataSet, statistics: [WindColumnStatistics], speeds: [WindColumnStatistics]) -> [WindFrequencyRose] {
        let lookup = Dictionary(uniqueKeysWithValues: dataset.columns.map { ($0.id, $0) })
        return statistics.filter { $0.kind == "wind_direction" && ["deg", "°", "Deg"].contains($0.unit) && $0.subtype == "Mean" }.compactMap { direction in
            guard let source = lookup[direction.id] else { return nil }
            // Association keys may be stale or point to a non-speed quantity.
            // Apply speed validity/calm rules only to an eligible speed sensor.
            var speedID = source.associatedSpeedID.flatMap { id in speeds.contains(where: { $0.id == id }) ? id : nil }
            if speedID == nil {
                let sameHeight = speeds.filter { speed in
                    guard let a = speed.height, let b = direction.height else { return false }
                    return abs(a - b) <= 0.01
                }
                if sameHeight.count == 1 { speedID = sameHeight[0].id }
                else if speeds.count == 1 { speedID = speeds[0].id }
            }
            let speed = speedID.flatMap { lookup[$0] }
            let threshold = dataset.metadata?.calmThreshold ?? 0
            var counts = Array(repeating: 0, count: 16)
            var total = 0
            var calm = 0
            for index in source.values.indices {
                guard let angle = valid(source.values[index], kind: "wind_direction") else { continue }
                var isCalm = false
                if let speed {
                    guard index < speed.values.count, let value = valid(speed.values[index], kind: "wind_speed") else { continue }
                    isCalm = value < threshold
                }
                total += 1
                if isCalm { calm += 1; continue }
                let normalized = angle >= 360 ? 0 : angle
                let sector = Int(floor((normalized + 11.25) / 22.5)) % 16
                counts[sector] += 1
            }
            let points = counts.enumerated().map { WindRoseFrequency(degrees: Double($0.offset) * 22.5,
                                                                    fraction: total > 0 ? Double($0.element) / Double(total) : 0) }
            return WindFrequencyRose(id: direction.id, label: direction.label, colorName: direction.colorName,
                                     points: points, validCount: total, calmCount: calm, associatedSpeedID: speed?.id)
        }
    }
}
