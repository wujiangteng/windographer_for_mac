import Foundation

public enum WindTimeSeriesMode: String, CaseIterable, Sendable {
    case measured, daily, monthly, annual
}

public struct WindTimeSeriesPoint: Sendable {
    public let timestamp: Date
    public let value: Double?
    public let validCount: Int
}

/// Source wall-clock timestamps are represented in UTC to avoid applying a
/// geographical time zone or a daylight-saving adjustment that the file lacks.
public enum TimeSeriesAnalysis {
    public static func points(dataset: WindExportDataSet, columnID: String,
                              mode: WindTimeSeriesMode) throws -> [WindTimeSeriesPoint] {
        try dataset.validate()
        guard let column = dataset.columns.first(where: { $0.id == columnID }) else {
            throw WindogError.invalid("time series column is unavailable: \(columnID)")
        }
        let step = Double(dataset.timeStepMinutes) * 60
        if mode == .measured {
            // Keep every sample, including explicit missing positions. Dropping
            // invalid records first would bridge gaps and shift decimation.
            return column.values.enumerated().map { index, raw in
                let value = valid(raw, column: column)
                return WindTimeSeriesPoint(timestamp: dataset.startDate.addingTimeInterval(Double(index) * step),
                                           value: value, validCount: value == nil ? 0 : 1)
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let component: Calendar.Component = mode == .daily ? .day : mode == .monthly ? .month : .year
        let coverageEnd = dataset.startDate.addingTimeInterval(Double(dataset.rowCount) * step)
        let lastSample = coverageEnd.addingTimeInterval(-step)
        guard let first = calendar.dateInterval(of: component, for: dataset.startDate)?.start,
              let last = calendar.dateInterval(of: component, for: lastSample)?.start else {
            throw WindogError.invalid("time series date range is unavailable")
        }
        let kind = column.kind ?? WindColumnMetadata.kind(label: column.label, unit: column.unit)
        let subtype = column.subtype ?? WindColumnMetadata.subtype(in: column.label)
        let vector = kind == "wind_direction" && subtype == "Mean"
        let speed = vector ? associatedSpeed(for: column, in: dataset) : nil
        var totals: [Date: Bucket] = [:]
        for index in 0..<dataset.rowCount {
            let start = dataset.startDate.addingTimeInterval(Double(index) * step)
            let raw = index < column.values.count ? valid(column.values[index], column: column) : nil
            let magnitude: Double?
            if let speed {
                magnitude = index < speed.values.count ? valid(speed.values[index], column: speed) : nil
            } else {
                magnitude = 1
            }
            let value = vector && magnitude == nil ? nil : raw
            if mode == .daily {
                // Daily resampling weights the fraction of each source interval
                // overlapping the target day, including non-divisor time steps.
                let intervalEnd = start.addingTimeInterval(step)
                var cursor = start
                while cursor < intervalEnd {
                    guard let bounds = calendar.dateInterval(of: .day, for: cursor) else { break }
                    let upper = min(intervalEnd, bounds.end)
                    let weight = upper.timeIntervalSince(cursor) / step
                    var bucket = totals[bounds.start] ?? Bucket()
                    bucket.add(value, magnitude: magnitude ?? 1, weight: weight, vector: vector)
                    totals[bounds.start] = bucket
                    cursor = upper
                }
            } else {
                // Monthly / annual native caches group sample timestamps.
                guard let key = calendar.dateInterval(of: component, for: start)?.start else { continue }
                var bucket = totals[key] ?? Bucket()
                bucket.add(value, magnitude: magnitude ?? 1, weight: 1, vector: vector)
                totals[key] = bucket
            }
        }
        let threshold = mode == .daily ? 0.75 : mode == .monthly ? 0.80 : 0.90
        var output: [WindTimeSeriesPoint] = []
        var key = first
        // An interval crossing midnight can contribute to the final day even
        // when its start is on the previous day.
        let lastKey = mode == .daily
            ? calendar.dateInterval(of: .day, for: coverageEnd.addingTimeInterval(-0.001))!.start : last
        while key <= lastKey {
            guard let bounds = calendar.dateInterval(of: component, for: key) else { break }
            let aggregate = totals[key] ?? Bucket()
            var value: Double?
            if aggregate.weight > 0 && aggregate.weight + 1e-10 >= aggregate.expected * threshold {
                if vector {
                    let degrees = atan2(aggregate.sine, aggregate.cosine) * 180 / .pi
                    let normalized = (degrees + 360).truncatingRemainder(dividingBy: 360)
                    value = normalized < 1e-10 || normalized > 360 - 1e-10 ? 0 : normalized
                } else if mode == .daily && subtype == "Min" {
                    value = aggregate.minimum
                } else if mode == .daily && subtype == "Max" {
                    value = aggregate.maximum
                } else if mode == .daily && subtype == "Std. dev." {
                    value = sqrt(aggregate.squareSum / aggregate.weight)
                } else {
                    value = aggregate.sum / aggregate.weight
                }
            }
            // Centers make each displayed mean represent its whole period.
            // The view keeps real calendar spacing; native month/year plotting
            // uses equal-width index bins (documented rendering difference).
            output.append(WindTimeSeriesPoint(timestamp: bounds.start.addingTimeInterval(bounds.duration / 2),
                                              value: value, validCount: aggregate.count))
            key = bounds.end
        }
        return output
    }

    private struct Bucket {
        var sum = 0.0
        var squareSum = 0.0
        var sine = 0.0
        var cosine = 0.0
        var weight = 0.0
        var expected = 0.0
        var count = 0
        var minimum = Double.infinity
        var maximum = -Double.infinity

        mutating func add(_ value: Double?, magnitude: Double, weight: Double, vector: Bool) {
            expected += weight
            guard let value else { return }
            self.weight += weight
            count += 1
            sum += weight * value
            squareSum += weight * value * value
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            if vector {
                sine += weight * magnitude * sin(value * .pi / 180)
                cosine += weight * magnitude * cos(value * .pi / 180)
            }
        }
    }

    private static func associatedSpeed(for direction: WindExportColumn, in dataset: WindExportDataSet) -> WindExportColumn? {
        let eligible = dataset.columns.filter {
            let kind = $0.kind ?? WindColumnMetadata.kind(label: $0.label, unit: $0.unit)
            return ["wind_speed", "wind_speed_synthesized"].contains(kind) && $0.unit == "m/s"
                && ($0.subtype ?? WindColumnMetadata.subtype(in: $0.label)) == "Mean"
        }
        if let id = direction.associatedSpeedID { return eligible.first { $0.id == id } }
        // Until the archive association map is decoded, the same conservative
        // height inference used by Summary applies; ambiguity uses unit vectors.
        let height = direction.height ?? WindColumnMetadata.height(in: direction.label)
        let sameHeight = eligible.filter {
            guard let height, let other = $0.height ?? WindColumnMetadata.height(in: $0.label) else { return false }
            return abs(height - other) < 0.01
        }
        if sameHeight.count == 1 { return sameHeight[0] }
        return eligible.count == 1 ? eligible[0] : nil
    }

    private static func valid(_ raw: Double?, column: WindExportColumn) -> Double? {
        guard let value = raw, value.isFinite, value != 9999, value != -9999, value != -999999 else { return nil }
        let kind = column.kind ?? WindColumnMetadata.kind(label: column.label, unit: column.unit)
        switch kind {
        case "wind_speed", "wind_speed_synthesized", "power_density": return value >= 0 ? value : nil
        case "wind_direction": return value >= 0 && value < 360.001 ? value : nil
        case "pressure", "density": return value > 0 ? value : nil
        case "temperature":
            let floor: Double = column.unit == "K" ? 0 : ["F", "°F"].contains(column.unit) ? -459.67 : -273.15
            return value >= floor ? value : nil
        default: return value
        }
    }
}
