import Foundation
import WindogCore

enum NativeTimeSeriesAnalysis {
    static func series(dataset: WindExportDataSet, channelID: String, mode: String) throws -> DecodedSeries {
        guard let mode = WindTimeSeriesMode(rawValue: mode),
              let column = dataset.columns.first(where: { $0.id == channelID }) else {
            throw WindogParser.ParserError.failed("Time series column or display mode is unavailable.")
        }
        let points = try TimeSeriesAnalysis.points(dataset: dataset, columnID: channelID, mode: mode)
        return DecodedSeries(name: channelID, colorName: column.colorName ?? "accent",
                             points: points.map {
            DecodedPoint(x: $0.timestamp.timeIntervalSince(dataset.startDate) / 86400, y: $0.value ?? .nan)
        })
    }
}
