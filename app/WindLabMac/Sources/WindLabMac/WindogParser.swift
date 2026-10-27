import Foundation
import WindogCore

struct WindogSummary {
    let fileName: String
    let sections: [DecodedPropertySection]
    let charts: DecodedCharts
    let configuration: DecodedDataSetConfiguration?
    let sourceData: WindExportDataSet
    let analysisData: WindExportDataSet
}

struct DecodedPropertySection: Decodable {
    let title: String
    let rows: [DecodedPropertyRow]
}

struct DecodedPropertyRow: Decodable {
    let label: String
    let value: String
}

struct DecodedCharts: Decodable {
    let shear: DecodedLineChart
    let rose: DecodedRoseChart
    let monthly: DecodedLineChart
    let diurnal: DecodedLineChart
    let timeSeries: DecodedTimeSeries
}

struct DecodedLineChart: Decodable {
    let series: [DecodedSeries]
}

struct DecodedRoseChart: Decodable {
    let series: [DecodedPolarSeries]
}

struct DecodedSeries: Decodable {
    let name: String
    let colorName: String
    let points: [DecodedPoint]
}

struct DecodedPolarSeries: Decodable {
    let name: String
    let colorName: String
    let points: [DecodedPolarPoint]
}

struct DecodedPoint: Decodable {
    let x: Double
    let y: Double
}

struct DecodedPolarPoint: Decodable {
    let degrees: Double
    let radius: Double
}

struct DecodedTimeSeries: Decodable {
    let series: [DecodedSeries]
    let channels: [DecodedTimeSeriesChannel]
    let monthLabels: [DecodedTimeAxisLabel]
    let startDate: String?
    let endDate: String?
    let years: [Int]?
}

struct DecodedTimeSeriesChannel: Decodable {
    let id: String
    let name: String
    let colorName: String
    let defaultVisible: Bool
    let unit: String
    let kind: String
}

struct DecodedDataSetConfiguration: Decodable {
    let columns: [DecodedDataColumnConfiguration]
    let dataSet: DecodedDataSetInformation
}

struct DecodedDataColumnConfiguration: Decodable {
    let id: String
    let label: String
    let unit: String
    let type: String
    let subtype: String
    let colorName: String
    let height: Double?
    let visible: Bool
    let mean: String
    let min: String
    let max: String
    let associated: DecodedAssociatedColumns
    let preview: DecodedColumnPreview
}

struct DecodedAssociatedColumns: Decodable {
    let stdDev: String
    let min: String
    let max: String
    let speed: String
}

struct DecodedColumnPreview: Decodable {
    let pdf: [DecodedHistogramBar]
    let diurnal: [DecodedPoint]
    let monthly: [DecodedMonthlyStatistic]
}

struct DecodedMonthlyStatistic: Decodable {
    let x: Double
    let min: Double
    let q1: Double
    let mean: Double
    let q3: Double
    let max: Double
}

struct DecodedDataSetInformation: Decodable {
    let name: String
    let description: String
    let latitude: Double
    let longitude: Double
    let elevation: Double
    let start: String
    let end: String
    let duration: String
    let timeStep: String
    let calmThreshold: Double
    let invalidValue: Double
    let timestampsIndicate: String
    let metadataSource: String
}

struct DecodedTimeAxisLabel: Decodable {
    let x: Double
    let label: String
}

struct DecodedHistogram: Decodable {
    let bars: [DecodedHistogramBar]
    let curve: [DecodedPoint]
    let xLabel: String
    let yLabel: String
    let weibull: String
}

struct DecodedHistogramBar: Decodable {
    let x: Double
    let y: Double
    let width: Double
}

struct DecodedDistributionAnalysis: Decodable {
    let bars: [DecodedHistogramBar]
    let curves: [DecodedSeries]
    let rows: [DecodedDistributionRow]
    let xLabel: String
    let yLabel: String
    let thresholdLabel: String
}

struct DecodedDistributionRow: Decodable {
    let algorithm: String
    let k: String
    let c: String
    let mean: String
    let proportionAbove: String
    let powerDensity: String
    let rSquared: String
}

enum WindogParser {
    static func exportDataSet(fileURL: URL, includingEmptyColumns: Bool = false) throws -> WindExportDataSet {
        if fileURL.pathExtension.lowercased() == "windog" {
            let document = try WindogDocument(contentsOf: fileURL)
            return WindExportDataSet(name: fileURL.deletingPathExtension().lastPathComponent,
                                     startDate: document.startDate, timeStepMinutes: document.timeStepMinutes,
                                     columns: document.columns.filter { includingEmptyColumns || $0.count > 0 }.map { column in
                WindExportColumn(id: column.channelID, label: column.name, unit: column.unit,
                                 values: document.values(for: column).map { $0.isFinite ? Double($0) : nil },
                                 height: WindColumnMetadata.height(in: column.name),
                                 kind: WindColumnMetadata.kind(label: column.name, unit: column.unit),
                                 subtype: WindColumnMetadata.subtype(in: column.name),
                                 flagIntervals: try? document.flagIntervals(for: column))
            }, flags: document.flags)
        }
        return try TextDataImporter.load(contentsOf: fileURL)
    }

    static func parse(fileURL: URL, configuration: DataSetConfiguration = .empty) throws -> WindogSummary {
        try NativeSummaryAnalysis.build(dataset: exportDataSet(fileURL: fileURL),
                                        configuration: configuration, fileName: fileURL.lastPathComponent)
    }

    static func parseTimeSeries(fileURL: URL, channelID: String, mode: String) throws -> DecodedSeries {
        try NativeTimeSeriesAnalysis.series(dataset: exportDataSet(fileURL: fileURL), channelID: channelID, mode: mode)
    }

    static func parseConfigurationPreview(fileURL: URL, channelID: String) throws -> DecodedColumnPreview {
        try NativeConfigurationAnalysis.preview(dataset: exportDataSet(fileURL: fileURL, includingEmptyColumns: true), channelID: channelID)
    }

    static func parseConfiguration(fileURL: URL) throws -> DecodedDataSetConfiguration {
        NativeConfigurationAnalysis.configuration(dataset: try exportDataSet(fileURL: fileURL, includingEmptyColumns: true), fileName: fileURL.lastPathComponent)
    }

    static func saveConfiguration(sourceURL: URL, destinationURL: URL, configuration: DataSetConfiguration) throws {
        guard sourceURL.pathExtension.lowercased() == "windog" else {
            throw ParserError.failed("Creating native .windog files from text is not supported yet. Open an existing .windog file to save changes.")
        }
        let document = try WindogDocument(contentsOf: sourceURL)
        let baseline = DataSetConfiguration(decoded: try parseConfiguration(fileURL: sourceURL))
        // The configuration panel is loaded lazily. Save/Save As before opening
        // it is a lossless copy, rather than an attempt to delete every column.
        let configuration = configuration.columns.isEmpty && configuration.dataSet == .empty
            ? baseline : configuration
        // Unrecovered properties must not be silently dropped or written at guessed offsets.
        func unsupportedProperties(_ value: DataSetConfiguration) throws -> NSDictionary {
            let data = try JSONEncoder().encode(EncodableDataSetConfiguration(value))
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["columns"] = (object["columns"] as! [[String: Any]]).map { item in
                var properties = item
                properties.removeValue(forKey: "label")
                properties.removeValue(forKey: "unit")
                return properties
            }
            return object as NSDictionary
        }
        guard try unsupportedProperties(configuration).isEqual(unsupportedProperties(baseline)) else {
            throw ParserError.failed("Native saving currently supports column labels and units. Other edited properties cannot yet be saved to .windog.")
        }
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.columns.map { ($0.id, $0) })
        let columnsByID = Dictionary(uniqueKeysWithValues: document.columns.map { ($0.channelID, $0) })
        let edits = try configuration.columns.map { column -> WindogColumnEdit in
            guard let original = columnsByID[column.id], let previous = baselineByID[column.id] else {
                throw ParserError.failed("The source columns changed. Reopen the file before saving.")
            }
            // Analysis normalizes units. Leave the source representation untouched
            // unless the user actually changed that field.
            let unit = column.unit == previous.unit ? original.unit : column.unit
            return WindogColumnEdit(index: original.index, name: column.label, unit: unit)
        }
        try document.applying(edits).write(to: destinationURL)
    }

    static func parseWindRose(
        fileURL: URL,
        display: String,
        versus: String,
        sectors: Int,
        directionID: String,
        dataIDs: [String],
        filterMode: String,
        year: String,
        month: String,
        rangeStart: String,
        rangeEnd: String,
        filterColumn: String = "-",
        filterMin: String = "-",
        filterMax: String = "-"
    ) throws -> DecodedRoseChart {
        let dataset = try exportDataSet(fileURL: fileURL)
        let selection = try NativeHistogramAnalysis.legacySelection(filterMode: filterMode, year: year, month: month,
            rangeStart: rangeStart, rangeEnd: rangeEnd, filterColumn: filterColumn, filterMin: filterMin, filterMax: filterMax)
        let metric: RoseDisplay = switch display {
        case "frequency": .frequency
        case "mean": .mean
        case "min": .minimum
        case "max": .maximum
        case "std. dev.": .standardDeviation
        case "total energy": .totalEnergy
        case "scatter plot": .scatter
        default: .occurrences
        }
        let grouping: RoseGrouping = switch versus {
        case "direction": .direction
        case "direction and month": .month
        case "direction and hour": .hour
        case "direction and bin": .bin
        default: .allDirections
        }
        let result = try WindRoseAnalysis.analyze(dataset, request: RoseRequest(
            directionID: directionID.isEmpty ? nil : directionID, dataIDs: dataIDs,
            grouping: grouping, display: metric, sectors: sectors, selection: selection))
        return DecodedRoseChart(series: result.series.map { item in
            DecodedPolarSeries(name: item.label, colorName: item.colorName ?? "accent", points:
                zip(result.sectorCenters, item.sectorValues).map { angle, value in
                    DecodedPolarPoint(degrees: angle, radius: value.map { item.unit == "%" ? $0 / 100 : $0 } ?? .nan)
                })
        })
    }

    static func parseHistogram(
        fileURL: URL,
        display: String,
        primaryID: String,
        width: String,
        start: String,
        filterMode: String,
        year: String,
        month: String,
        rangeStart: String,
        rangeEnd: String,
        filterColumn: String,
        filterMin: String,
        filterMax: String,
        halfFirstBin: Bool = false
    ) throws -> DecodedHistogram {
        let dataset = try exportDataSet(fileURL: fileURL)
        let selection = try NativeHistogramAnalysis.legacySelection(filterMode: filterMode, year: year, month: month,
            rangeStart: rangeStart, rangeEnd: rangeEnd, filterColumn: filterColumn, filterMin: filterMin, filterMax: filterMax)
        func number(_ text: String) throws -> Double? {
            if text == "-" { return nil }
            guard let value = Double(text), value.isFinite else { throw WindogError.invalid("Invalid bin setting") }
            return value
        }
        let page = try NativeHistogramAnalysis.build(dataset: dataset, request: HistogramRequest(primaryID: primaryID,
            primaryBins: HistogramBinSettings(width: try number(width), start: try number(start), halfFirst: halfFirstBin), selection: selection))
        let frequency = display == "frequency"
        return DecodedHistogram(bars: page.result.bins.indices.map {
            DecodedHistogramBar(x: page.result.bins[$0].center,
                                y: page.value(row: $0, group: 0, frequency: frequency, table: false), width: page.result.bins[$0].width)
        }, curve: frequency ? page.curve.map { DecodedPoint(x: $0.x, y: $0.frequency) } : [],
        xLabel: "\(page.primaryLabel) [\(page.primaryUnit)]", yLabel: frequency ? "Frequency (%)" : "Occurrences", weibull: page.fitLabel ?? "-")
    }

    static func parseDistributionAnalysis(
        fileURL: URL,
        primaryID: String,
        width: String,
        start: String,
        filterMode: String,
        year: String,
        month: String,
        rangeStart: String,
        rangeEnd: String,
        filterColumn: String,
        filterMin: String,
        filterMax: String,
        halfFirstBin: Bool = false
    ) throws -> DecodedDistributionAnalysis {
        let result = try NativeDistributionAnalysis.result(
            fileURL: fileURL, primaryID: primaryID, width: width, start: start, halfFirstBin: halfFirstBin,
            filterMode: filterMode, year: year, month: month, rangeStart: rangeStart, rangeEnd: rangeEnd,
            filterColumn: filterColumn, filterMin: filterMin, filterMax: filterMax)
        return NativeDistributionAnalysis.analysis(result)
    }

    enum ParserError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message):
                return message
            }
        }
    }


}

private struct EncodableDataSetConfiguration: Encodable {
    let columns: [EncodableDataColumnConfiguration]
    let dataSet: EncodableDataSetInformation

    init(_ configuration: DataSetConfiguration) {
        columns = configuration.columns.map(EncodableDataColumnConfiguration.init)
        dataSet = EncodableDataSetInformation(configuration.dataSet)
    }
}

private struct EncodableDataColumnConfiguration: Encodable {
    let id: String
    let label: String
    let unit: String
    let type: String
    let subtype: String
    let colorName: String
    let height: Double?
    let visible: Bool
    let associated: EncodableAssociatedColumns

    init(_ column: DataColumnConfiguration) {
        id = column.id
        label = column.label
        unit = column.unit
        type = column.type
        subtype = column.subtype
        colorName = column.colorName
        height = column.height
        visible = column.visible
        associated = EncodableAssociatedColumns(column.associated)
    }
}

private struct EncodableAssociatedColumns: Encodable {
    let stdDev: String
    let min: String
    let max: String
    let speed: String

    init(_ associated: AssociatedColumns) {
        stdDev = associated.stdDev
        min = associated.min
        max = associated.max
        speed = associated.speed
    }
}

private struct EncodableDataSetInformation: Encodable {
    let name: String
    let description: String
    let latitude: Double
    let longitude: Double
    let elevation: Double
    let calmThreshold: Double
    let invalidValue: Double
    let timestampsIndicate: String

    init(_ dataSet: DataSetInformation) {
        name = dataSet.name
        description = dataSet.description
        latitude = dataSet.latitude
        longitude = dataSet.longitude
        elevation = dataSet.elevation
        calmThreshold = dataSet.calmThreshold
        invalidValue = dataSet.invalidValue
        timestampsIndicate = dataSet.timestampsIndicate
    }
}
