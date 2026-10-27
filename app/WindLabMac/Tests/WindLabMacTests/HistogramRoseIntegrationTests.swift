import XCTest
import SwiftUI
import WindogCore
@testable import WindLabMac

final class HistogramRoseIntegrationTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testGroupedHistogramGraphAndTableUseNativeDifferentDenominators() throws {
        let dataset = WindExportDataSet(name: "months", startDate: date("2021-01-01T00:00:00Z"), timeStepMinutes: 1440,
            columns: [WindExportColumn(id: "speed", label: "Speed", unit: "m/s", values: Array(repeating: 1, count: 31) + Array(repeating: 2, count: 28))])
        let page = try NativeHistogramAnalysis.build(dataset: dataset, request: HistogramRequest(primaryID: "speed", grouping: .month,
            primaryBins: HistogramBinSettings(width: 1, start: 0)))
        let row = try XCTUnwrap(page.result.bins.firstIndex { $0.lower <= 1 && $0.upper > 1 })
        XCTAssertEqual(page.value(row: row, group: 0, frequency: true, table: false), 100)
        XCTAssertEqual(page.value(row: row, group: 0, frequency: true, table: true), 100 * 31.0 / 59, accuracy: 1e-9)
        XCTAssertTrue(page.tableText(frequency: true, delimiter: ",").contains("Jan (%)"))
        XCTAssertTrue(page.normalization(frequency: true, table: true).contains("Joint"))
    }

    func testHistogramCurveUsesTwoHundredPointsAndActualFirstWidth() throws {
        let values: [Double] = [0.1,0.2,0.5,1,2,3,4,5,6,7,8]
        let dataset = WindExportDataSet(name: "speed", startDate: date("2021-01-01T00:00:00Z"), timeStepMinutes: 60,
            columns: [WindExportColumn(id: "speed", label: "Mean speed", unit: "m/s", values: values.map(Optional.some))])
        let page = try NativeHistogramAnalysis.build(dataset: dataset, request: HistogramRequest(primaryID: "speed",
            primaryBins: HistogramBinSettings(width: 1, start: 0, halfFirst: true)))
        let fit = try XCTUnwrap(WeibullAnalysis.maximumLikelihood(values))
        XCTAssertEqual(page.curve.count, 200)
        for point in page.curve { XCTAssertEqual(point.frequency, fit.density(point.x) * 0.5 * 100, accuracy: 1e-10) }
    }

    func testDecodedFlagsActuallyChangeHistogramSelectionWithoutChangingSource() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let dataset = try WindogParser.exportDataSet(fileURL: url.appendingPathComponent("test-data/source.windog"))
        let column = try XCTUnwrap(dataset.columns.first { $0.label.contains("100 m") })
        XCTAssertNotNil(column.flagIntervals)
        XCTAssertNotNil(dataset.flags)
        let filtered = NativeFlagFiltering.applying(to: dataset, enabled: true, includeUnflagged: true, flagIDs: [])
        XCTAssertTrue(try XCTUnwrap(filtered.columns.first { $0.id == column.id }).values.allSatisfy { $0 == nil })
        XCTAssertTrue(column.values.contains { $0 != nil })
        let restored = NativeFlagFiltering.applying(to: dataset, enabled: true, includeUnflagged: false, flagIDs: [103])
        let histogram = try NativeHistogramAnalysis.build(dataset: restored, request: HistogramRequest(primaryID: column.id))
        XCTAssertGreaterThan(histogram.result.sampleCount, 8000)
    }

    func testRoseStatisticsAndScatterTablesExportActualValuesWithUnits() throws {
        let dataset = WindExportDataSet(name: "rose", startDate: date("2021-01-01T00:00:00Z"), timeStepMinutes: 60,
            columns: [WindExportColumn(id: "direction", label: "Direction", unit: "deg", values: [0,0,90,90], kind: "wind_direction"),
                      WindExportColumn(id: "temperature", label: "Temperature", unit: "C", values: [-4,-2,2,4], kind: "temperature")])
        let mean = try WindRoseAnalysis.analyze(dataset, request: RoseRequest(directionID: "direction", dataIDs: ["temperature"], grouping: .direction, display: .mean))
        XCTAssertEqual(mean.series[0].sectorValues[0], -3)
        XCTAssertTrue(NativeRoseTable.text(mean, display: .mean).contains("Temperature [C]"))
        let scatter = try WindRoseAnalysis.analyze(dataset, request: RoseRequest(directionID: "direction", dataIDs: ["temperature"], grouping: .direction, display: .scatter))
        XCTAssertEqual(scatter.series[0].scatterPoints.count, 4)
        XCTAssertTrue(NativeRoseTable.text(scatter, display: .scatter, delimiter: ",").contains("\"-4\""))
    }

    func testCurrentScreenshotFileComputesEveryHistogramGroupingAndRoseDisplay() throws {
        let url = URL(fileURLWithPath: "/Users/wudong/Documents/Data/Mast/测风数据/测风塔-海上新增/8468_0273-20201201-20221130-风向矫正-异塔插补2-0.174拟合.windog")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Screenshot file unavailable") }
        let source = try WindogParser.exportDataSet(fileURL: url)
        let dataset = NativeFlagFiltering.applying(to: source, enabled: true, includeUnflagged: true, flagIDs: [103])
        let speeds = dataset.columns.filter { $0.kind == "wind_speed" && $0.subtype == "Mean" }
        let speed = try XCTUnwrap(speeds.first)
        let direction = try XCTUnwrap(dataset.columns.first { $0.kind == "wind_direction" && $0.subtype == "Mean" })
        for grouping in HistogramGrouping.allCases {
            let result = try HistogramAnalysis.analyze(dataset, request: HistogramRequest(primaryID: speed.id, grouping: grouping,
                secondaryID: try XCTUnwrap(speeds.dropFirst().first).id))
            XCTAssertGreaterThan(result.includedCount, 1000)
            XCTAssertEqual(result.counts.flatMap { $0 }.reduce(0,+), result.includedCount)
        }
        for display in RoseDisplay.allCases {
            let result = try WindRoseAnalysis.analyze(dataset, request: RoseRequest(directionID: direction.id,
                dataIDs: [speed.id], grouping: .direction, display: display))
            XCTAssertGreaterThan(result.overallValidCount, 1000)
            XCTAssertFalse(result.series.isEmpty)
            if display == .scatter { XCTAssertGreaterThan(result.series[0].scatterPoints.count, 1000) }
        }
        for grouping in [RoseGrouping.month, .hour, .bin] {
            let result = try WindRoseAnalysis.analyze(dataset, request: RoseRequest(directionID: direction.id,
                dataIDs: [speed.id], grouping: grouping, display: .frequency, binID: speed.id))
            XCTAssertFalse(result.series.isEmpty)
            if grouping != .bin { XCTAssertEqual(result.series.count, 12) }
        }
    }

    @MainActor func testHistogramAndRoseImageExportRendersNonemptyImages() throws {
        let dataset = WindExportDataSet(name: "render", startDate: date("2021-01-01T00:00:00Z"), timeStepMinutes: 60,
            columns: [WindExportColumn(id: "speed", label: "Speed", unit: "m/s", values: [1,2,3,4]),
                      WindExportColumn(id: "direction", label: "Direction", unit: "deg", values: [0,90,180,270], kind: "wind_direction")])
        let histogram = try NativeHistogramAnalysis.build(dataset: dataset, request: HistogramRequest(primaryID: "speed"))
        let renderer = ImageRenderer(content: HistogramVisualization(presentation: histogram, frequency: true, showFit: true,
            visibleGroups: [0], showAggregate: true).frame(width: 600, height: 400).background(.white))
        XCTAssertNotNil(renderer.nsImage?.tiffRepresentation)
        let joint = try NativeHistogramAnalysis.build(dataset: dataset, request: HistogramRequest(primaryID: "speed", grouping: .column, secondaryID: "direction"))
        let jointRenderer = ImageRenderer(content: HistogramVisualization(presentation: joint, frequency: true, showFit: false,
            visibleGroups: [], showAggregate: true, surfaceStyle: .constant(.surface), showsControls: false)
            .frame(width: 600, height: 400).background(.white))
        XCTAssertNotNil(jointRenderer.nsImage?.tiffRepresentation)
        let rose = try WindRoseAnalysis.analyze(dataset, request: RoseRequest(display: .frequency))
        let roseRenderer = ImageRenderer(content: WindRoseVisualization(result: rose, display: .frequency,
            visibleIDs: Set(rose.series.map(\.id)), style: .line).frame(width: 600, height: 600).background(.white))
        XCTAssertNotNil(roseRenderer.nsImage?.tiffRepresentation)
    }
}
