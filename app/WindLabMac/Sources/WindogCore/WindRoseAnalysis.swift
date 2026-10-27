import Foundation

public enum RoseDisplay: String, CaseIterable, Sendable {
    case occurrences, frequency, mean, minimum, maximum, standardDeviation, totalEnergy, scatter
}

public enum RoseGrouping: String, CaseIterable, Sendable {
    case allDirections, direction, month, hour, bin
}

public struct RoseRequest: Sendable {
    public var directionID: String?
    public var dataIDs: [String]
    public var grouping: RoseGrouping
    public var display: RoseDisplay
    public var sectors: Int
    public var binID: String?
    public var speedID: String?
    public var bins: HistogramBinSettings
    public var selection: HistogramSelection

    public init(directionID: String? = nil, dataIDs: [String] = [], grouping: RoseGrouping = .allDirections,
                display: RoseDisplay = .occurrences, sectors: Int = 16, binID: String? = nil,
                speedID: String? = nil, bins: HistogramBinSettings = .init(), selection: HistogramSelection = .init()) {
        self.directionID = directionID
        self.dataIDs = dataIDs
        self.grouping = grouping
        self.display = display
        self.sectors = sectors
        self.binID = binID
        self.speedID = speedID
        self.bins = bins
        self.selection = selection
    }
}

public struct RoseScatterPoint: Sendable {
    public let direction: Double
    public let value: Double
}

public struct RoseSeriesResult: Sendable {
    public let id: String
    public let label: String
    public let colorName: String?
    /// Frequency and totalEnergy use native percentages, not fractions.
    public let sectorValues: [Double?]
    public let counts: [Int]
    public let scatterPoints: [RoseScatterPoint]
    public let validCount: Int
    public let calmCount: Int
    public let unit: String
}

public struct RoseResult: Sendable {
    public let sectorCenters: [Double]
    public let series: [RoseSeriesResult]
    /// Distinct source rows contributing to at least one selected series.
    public let overallValidCount: Int
    public let calmCount: Int
    public let notes: [String]
}

/// Sector statistics reconstructed from the inspected wind-rose page. Generic
/// data statistics include calm samples; the all-direction frequency comparison
/// uses the separate associated-speed calm rule recovered for Summary.
public enum WindRoseAnalysis {
    public static func analyze(_ dataset: WindExportDataSet, request: RoseRequest) throws -> RoseResult {
        try dataset.validate()
        guard (4...360).contains(request.sectors) else { throw WindogError.invalid("wind rose sectors must be between 4 and 360") }
        let lookup = Dictionary(uniqueKeysWithValues: dataset.columns.map { ($0.id, $0) })
        let directions = dataset.columns.filter { kind($0) == "wind_direction" && subtype($0) == "Mean" && ["deg", "°", "Deg"].contains($0.unit) }
        guard !directions.isEmpty else { throw WindogError.invalid("no mean wind-direction column is available") }
        let direction: WindExportColumn
        if let id = request.directionID {
            guard let selected = directions.first(where: { $0.id == id }) else { throw WindogError.invalid("wind rose direction column is unavailable") }
            direction = selected
        } else { direction = directions[0] }
        var selection = request.selection
        if request.grouping == .month { selection.month = nil }
        try validate(selection)
        let filter: WindExportColumn?
        if let id = selection.columnID {
            guard let selected = lookup[id] else { throw WindogError.invalid("wind rose filter column is unavailable") }
            filter = selected
        } else { filter = nil }
        if let id = request.speedID, !dataset.columns.contains(where: { $0.id == id && isMeanSpeed($0) }) {
            throw WindogError.invalid("wind rose speed column must be a mean wind speed in m/s")
        }
        let selectedData = try request.dataIDs.map { id -> WindExportColumn in
            guard let selected = lookup[id] else { throw WindogError.invalid("wind rose data column is unavailable: \(id)") }
            return selected
        }
        let width = 360 / Double(request.sectors)
        let centers = (0..<request.sectors).map { Double($0) * width }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var notes: [String] = []
        var validRows = Set<Int>()
        var calmRows = Set<Int>()
        let step = Double(dataset.timeStepMinutes) * 60
        let threshold = dataset.metadata?.calmThreshold ?? 0
        guard threshold.isFinite, threshold >= 0 else { throw WindogError.invalid("wind rose calm threshold must be nonnegative") }
        var output: [RoseSeriesResult] = []

        func allowed(_ index: Int, date: Date) -> Bool {
            if let indices = selection.includedIndices, !indices.contains(index) { return false }
            if let start = selection.startDate, date < start { return false }
            if let end = selection.endDate, date >= end { return false }
            if let year = selection.year, calendar.component(.year, from: date) != year { return false }
            if let month = selection.month, calendar.component(.month, from: date) != month { return false }
            if let filter {
                guard index < filter.values.count, let value = valid(filter.values[index], column: filter) else { return false }
                if let minimum = selection.minimum, value < minimum { return false }
                if let maximum = selection.maximum, value > maximum { return false }
            }
            return true
        }
        func sector(_ angle: Double) -> Int {
            Int(floor(((angle >= 360 ? 0 : angle) + width / 2) / width)) % request.sectors
        }
        if request.grouping == .allDirections {
            guard request.display == .occurrences || request.display == .frequency else {
                throw WindogError.invalid("choose one direction sensor and data columns for wind rose statistics")
            }
            if dataset.metadata?.calmThreshold == nil { notes.append("Calm threshold is unavailable; 0 m/s is assumed.") }
            for column in directions {
                let speed = associatedSpeed(direction: column, requestID: request.speedID, dataset: dataset)
                if speed == nil && threshold > 0 { notes.append("No speed association is available for \(column.label); calm separation is unavailable.") }
                var counts = Array(repeating: 0, count: request.sectors)
                var total = 0
                var calm = 0
                for index in column.values.indices {
                    let date = dataset.startDate.addingTimeInterval(Double(index) * step)
                    guard allowed(index, date: date), let angle = valid(column.values[index], column: column) else { continue }
                    if let speed {
                        guard index < speed.values.count, let value = valid(speed.values[index], column: speed) else { continue }
                        total += 1
                        validRows.insert(index)
                        if value < threshold { calm += 1; calmRows.insert(index); continue }
                    } else { total += 1; validRows.insert(index) }
                    counts[sector(angle)] += 1
                }
                let values: [Double?] = counts.map {
                    request.display == .frequency ? (total > 0 ? Double($0) * 100 / Double(total) : 0) : Double($0)
                }
                output.append(RoseSeriesResult(id: column.id, label: column.label, colorName: column.colorName,
                    sectorValues: values, counts: counts, scatterPoints: [], validCount: total, calmCount: calm,
                    unit: request.display == .frequency ? "%" : "count"))
            }
            return RoseResult(sectorCenters: centers, series: output, overallValidCount: validRows.count,
                              calmCount: calmRows.count, notes: notes)
        }

        if request.display == .totalEnergy && request.grouping != .direction && request.grouping != .month {
            throw WindogError.invalid("total wind energy supports direction or direction-and-month grouping")
        }
        let sourceColumns: [WindExportColumn]
        if selectedData.isEmpty {
            if request.display == .occurrences || request.display == .frequency { sourceColumns = [direction] }
            else { throw WindogError.invalid("select at least one wind rose data column") }
        } else { sourceColumns = selectedData }
        let groups: [(label: String, lower: Double?, upper: Double?)]
        let binColumn: WindExportColumn?
        let binEdges: [HistogramBin]?
        switch request.grouping {
        case .month:
            groups = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].map { ($0, nil, nil) }
            binColumn = nil; binEdges = nil
        case .hour:
            groups = (0..<12).map { (String(format: "%02d:00 – %02d:00", $0 * 2, ($0 + 1) * 2), nil, nil) }
            binColumn = nil; binEdges = nil
        case .bin:
            guard let id = request.binID, let column = lookup[id] else { throw WindogError.invalid("select an available wind rose bin column") }
            var values: [Double] = []
            for index in direction.values.indices {
                let date = dataset.startDate.addingTimeInterval(Double(index) * step)
                guard allowed(index, date: date), valid(direction.values[index], column: direction) != nil,
                      index < column.values.count, let binValue = valid(column.values[index], column: column),
                      sourceColumns.contains(where: { index < $0.values.count && valid($0.values[index], column: $0) != nil }) else { continue }
                values.append(binValue)
            }
            guard !values.isEmpty else { throw WindogError.invalid("no valid wind rose bin triplets match the selection") }
            let edges = try HistogramAnalysis.makeBins(values: values, settings: request.bins, minimumCount: 20, maximumCount: 40)
            groups = edges.map { ("\(format($0.lower)) – \(format($0.upper))", $0.lower, $0.upper) }
            binColumn = column; binEdges = edges
        default:
            groups = [("", nil, nil)]; binColumn = nil; binEdges = nil
        }
        guard groups.count * sourceColumns.count * request.sectors <= 1_000_000 else {
            throw WindogError.invalid("too many wind rose cells; increase bin width or select fewer columns")
        }
        for column in sourceColumns {
            let valuesColumn: WindExportColumn
            let energyFallback: Bool
            if request.display == .totalEnergy {
                guard isMeanSpeed(column) else { throw WindogError.invalid("total wind energy requires mean wind-speed columns in m/s") }
                if let power = powerDensity(for: column, dataset: dataset) {
                    valuesColumn = power; energyFallback = false
                    notes.append("Wind power density for \(column.label) uses the available height/association match \(power.label).")
                } else {
                    valuesColumn = column; energyFallback = true
                    notes.append("No stored power-density association is available for \(column.label); energy proportions use a constant-density speed³ estimate.")
                }
            } else { valuesColumn = column; energyFallback = false }
            var accumulators = Array(repeating: Array(repeating: Accumulator(), count: request.sectors), count: groups.count)
            var totals = Array(repeating: 0, count: groups.count)
            var normalizationCount = 0
            var scatter = Array(repeating: [RoseScatterPoint](), count: groups.count)
            for index in direction.values.indices {
                let date = dataset.startDate.addingTimeInterval(Double(index) * step)
                guard allowed(index, date: date), let angle = valid(direction.values[index], column: direction),
                      index < valuesColumn.values.count, let raw = valid(valuesColumn.values[index], column: valuesColumn) else { continue }
                let group: Int
                switch request.grouping {
                case .month: group = calendar.component(.month, from: date) - 1
                case .hour: group = calendar.component(.hour, from: date) / 2
                case .bin:
                    guard let binColumn, let binEdges, index < binColumn.values.count,
                          let binValue = valid(binColumn.values[index], column: binColumn) else { continue }
                    normalizationCount += 1
                    validRows.insert(index)
                    guard let selected = binIndex(binValue, bins: binEdges) else { continue }
                    group = selected
                default: group = 0
                }
                let value = energyFallback ? raw * raw * raw : raw
                guard value.isFinite else { continue }
                let indexOfSector = sector(angle)
                accumulators[group][indexOfSector].add(value)
                totals[group] += 1
                if request.grouping != .bin { normalizationCount += 1 }
                validRows.insert(index)
                if request.display == .scatter {
                    scatter[group].append(RoseScatterPoint(direction: angle >= 360 ? 0 : angle, value: value))
                }
            }
            for group in groups.indices {
                let groupName = groups[group].label
                let label = groupName.isEmpty ? column.label : (sourceColumns.count == 1 ? groupName : "\(column.label) · \(groupName)")
                let totalEnergy = accumulators[group].reduce(0) { $0 + $1.sum }
                let values = accumulators[group].map { item -> Double? in
                    switch request.display {
                    case .occurrences: return Double(item.count)
                    case .frequency:
                        let denominator = request.grouping == .bin ? normalizationCount : totals[group]
                        return denominator > 0 ? Double(item.count) * 100 / Double(denominator) : 0
                    case .totalEnergy: return totalEnergy > 0 ? item.sum * 100 / totalEnergy : 0
                    case .mean: return item.count > 0 ? item.mean : nil
                    case .minimum: return item.count > 0 ? item.minimum : nil
                    case .maximum: return item.count > 0 ? item.maximum : nil
                    case .standardDeviation: return item.count > 0 ? (item.count > 1 ? sqrt(max(0, item.m2 / Double(item.count - 1))) : 0) : nil
                    case .scatter: return nil
                    }
                }
                let unit: String = request.display == .frequency || request.display == .totalEnergy ? "%" : request.display == .occurrences ? "count" : column.unit
                output.append(RoseSeriesResult(id: "\(column.id)|\(group)", label: label, colorName: column.colorName,
                    sectorValues: values, counts: accumulators[group].map(\.count), scatterPoints: scatter[group],
                    validCount: totals[group], calmCount: 0, unit: unit))
            }
        }
        return RoseResult(sectorCenters: centers, series: output, overallValidCount: validRows.count,
                          calmCount: 0, notes: Array(Set(notes)).sorted())
    }

    private struct Accumulator {
        var count = 0
        var sum = 0.0
        var mean = 0.0
        var m2 = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        mutating func add(_ value: Double) {
            count += 1
            sum += value
            let delta = value - mean
            mean += delta / Double(count)
            m2 += delta * (value - mean)
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
    }

    private static func kind(_ column: WindExportColumn) -> String { column.kind ?? WindColumnMetadata.kind(label: column.label, unit: column.unit) }
    private static func subtype(_ column: WindExportColumn) -> String { column.subtype ?? WindColumnMetadata.subtype(in: column.label) }
    private static func isMeanSpeed(_ column: WindExportColumn) -> Bool {
        ["wind_speed", "wind_speed_synthesized"].contains(kind(column)) && subtype(column) == "Mean" && column.unit == "m/s"
    }
    private static func associatedSpeed(direction: WindExportColumn, requestID: String?, dataset: WindExportDataSet) -> WindExportColumn? {
        let speeds = dataset.columns.filter(isMeanSpeed)
        if let id = requestID ?? direction.associatedSpeedID { return speeds.first { $0.id == id } }
        let height = direction.height ?? WindColumnMetadata.height(in: direction.label)
        let sameHeight = speeds.filter {
            guard let height, let other = $0.height ?? WindColumnMetadata.height(in: $0.label) else { return false }
            return abs(height - other) < 0.01
        }
        if sameHeight.count == 1 { return sameHeight[0] }
        return speeds.count == 1 ? speeds[0] : nil
    }
    private static func powerDensity(for speed: WindExportColumn, dataset: WindExportDataSet) -> WindExportColumn? {
        let powers = dataset.columns.filter { kind($0) == "power_density" && subtype($0) == "Mean" && ["W/m2", "W/m²", "W/m^2", ""].contains($0.unit) }
        let explicit = powers.filter { $0.associatedSpeedID == speed.id }
        if explicit.count == 1 { return explicit[0] }
        let height = speed.height ?? WindColumnMetadata.height(in: speed.label)
        let sameHeight = powers.filter {
            guard let height, let other = $0.height ?? WindColumnMetadata.height(in: $0.label) else { return false }
            return abs(height - other) < 0.01
        }
        return sameHeight.count == 1 ? sameHeight[0] : nil
    }
    private static func valid(_ raw: Double?, column: WindExportColumn) -> Double? {
        guard let value = raw, value.isFinite, value != 9999, value != -9999, value != -999999 else { return nil }
        switch kind(column) {
        case "wind_speed", "wind_speed_synthesized", "power_density": return value >= 0 ? value : nil
        case "wind_direction": return value >= 0 && value < 360.001 ? value : nil
        case "pressure", "density": return value > 0 ? value : nil
        case "temperature":
            let minimum = column.unit == "K" ? 0.0 : ["F", "°F"].contains(column.unit) ? -459.67 : -273.15
            return value >= minimum ? value : nil
        default: return value
        }
    }
    private static func binIndex(_ value: Double, bins: [HistogramBin]) -> Int? {
        guard let first = bins.first, let last = bins.last, value >= first.lower, value <= last.upper else { return nil }
        if value == last.upper { return bins.count - 1 }
        return bins.firstIndex { value >= $0.lower && value < $0.upper }
    }
    private static func validate(_ selection: HistogramSelection) throws {
        if let year = selection.year, !(1...9999).contains(year) { throw WindogError.invalid("invalid wind rose year") }
        if let month = selection.month, !(1...12).contains(month) { throw WindogError.invalid("invalid wind rose month") }
        if let minimum = selection.minimum, !minimum.isFinite { throw WindogError.invalid("invalid wind rose minimum") }
        if let maximum = selection.maximum, !maximum.isFinite { throw WindogError.invalid("invalid wind rose maximum") }
        if let minimum = selection.minimum, let maximum = selection.maximum, minimum > maximum { throw WindogError.invalid("wind rose minimum exceeds maximum") }
        if let start = selection.startDate, !start.timeIntervalSince1970.isFinite { throw WindogError.invalid("invalid wind rose start date") }
        if let end = selection.endDate, !end.timeIntervalSince1970.isFinite { throw WindogError.invalid("invalid wind rose end date") }
        if let start = selection.startDate, let end = selection.endDate, start >= end { throw WindogError.invalid("wind rose date range is empty") }
    }
    private static func format(_ value: Double) -> String { String(format: "%.6g", value) }
}
