import XCTest
import WindogCore
@testable import WindLabMac

final class WindogIntegrationTests: XCTestCase {
    func testSwiftDistributionPageAndHistogramUseRecoveredAlgorithms() throws {
        let file = try source()
        let id = try XCTUnwrap(WindogParser.exportDataSet(fileURL: file).columns.first?.id)
        let analysis = try WindogParser.parseDistributionAnalysis(
            fileURL: file, primaryID: id, width: "-", start: "-", filterMode: "none",
            year: "-", month: "-", rangeStart: "-", rangeEnd: "-",
            filterColumn: "-", filterMin: "-", filterMax: "-")
        XCTAssertEqual(analysis.rows.count, 4)
        XCTAssertEqual(analysis.rows[0].k, "2.158")
        XCTAssertEqual(analysis.rows[1].k, "1.999")
        XCTAssertEqual(analysis.rows[2].k, "2.376")
        XCTAssertEqual(analysis.rows[2].powerDensity, "987.9")
        XCTAssertEqual(analysis.rows[3].powerDensity, "987.9")
        XCTAssertTrue(analysis.rows[3].algorithm.contains("8,753"))
        XCTAssertEqual(analysis.curves[0].points.count, 100)
        let histogram = try WindogParser.parseHistogram(
            fileURL: file, display: "occurrences", primaryID: id, width: "0.5", start: "0", filterMode: "none",
            year: "-", month: "-", rangeStart: "-", rangeEnd: "-",
            filterColumn: "-", filterMin: "-", filterMax: "-", halfFirstBin: true)
        XCTAssertEqual(histogram.bars.first?.width, 0.25)
        XCTAssertEqual(histogram.bars.reduce(0) { $0 + $1.y }, 8753)
        let firstDay = try WindogParser.parseDistributionAnalysis(
            fileURL: file, primaryID: id, width: "-", start: "-", filterMode: "range",
            year: "-", month: "-", rangeStart: "2022-07-01", rangeEnd: "2022-07-01",
            filterColumn: "-", filterMin: "-", filterMax: "-")
        XCTAssertTrue(firstDay.rows.last?.algorithm.contains("24 time steps") == true)
    }

    func testNativeExportsRoundTripThroughTextImporter() throws {
        let dataset = try WindogParser.exportDataSet(fileURL: source())
        XCTAssertEqual(dataset.columns.count, 4)
        XCTAssertEqual(dataset.rowCount, 8760)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = try dataset.selecting(ids: [dataset.columns[0].id],
                                            end: dataset.startDate.addingTimeInterval(3600))
        for format in [WindExportFormat.csv, .tsv, .windographerText] {
            let output = directory.appendingPathComponent("exported." + format.fileExtension)
            try DelimitedDataExporter.write(selected, format: format, to: output)
            let reopened = try WindogParser.exportDataSet(fileURL: output)
            XCTAssertEqual(reopened.rowCount, 2)
            XCTAssertEqual(reopened.startDate, selected.startDate)
            XCTAssertEqual(reopened.timeStepMinutes, 60)
            XCTAssertEqual(reopened.columns[0].values, selected.columns[0].values)
        }
    }

    func testSummaryTextAndChartsShareRawSwiftStatistics() throws {
        let dataset = try WindogParser.exportDataSet(fileURL: source())
        let result = try SummaryStatistics.analyze(dataset)
        let summary = try NativeSummaryAnalysis.build(dataset: dataset)
        let rows = Dictionary(uniqueKeysWithValues: summary.sections.flatMap(\.rows).map { ($0.label, $0.value) })
        XCTAssertEqual(rows["MoMM at 150 m:"], String(format: "%.3f m/s", try XCTUnwrap(result.meanAtHighestHeight)))
        XCTAssertEqual(rows["Mean air density:"], "n/a")
        XCTAssertEqual(rows["Mean temperature:"], "n/a")
        XCTAssertEqual(rows["MoMM WPD (50m):"], "n/a")
        XCTAssertEqual(rows["Latitude:"], "n/a")
        XCTAssertEqual(rows["Last sample:"], "2023/6/30 23:00")
        XCTAssertEqual(summary.charts.monthly.series.count, 2)
        for series in summary.charts.monthly.series {
            let statistics = try XCTUnwrap(result.columns.first { $0.label == series.name })
            XCTAssertEqual(series.points.count, 12)
            XCTAssertEqual(series.points.map(\.y), statistics.monthly.map { $0.mean ?? .nan })
        }
        XCTAssertTrue(summary.charts.diurnal.series.allSatisfy { $0.points.count == 24 })
        XCTAssertEqual(summary.charts.shear.series[0].points.map(\.x), result.shear.measured.map(\.speed))
        XCTAssertEqual(rows["Power law exponent:"], String(format: "%.3f", try XCTUnwrap(result.shear.powerExponent)))
        XCTAssertEqual(summary.charts.rose.series.first?.points.count, 16)
        print("Swift Summary sample: \(rows)")
    }

    func testSummaryConfigurationRecalculatesInsteadOfUsingRoundedPreview() throws {
        let url = try source()
        let dataset = try WindogParser.exportDataSet(fileURL: url)
        var configuration = DataSetConfiguration(decoded: try WindogParser.parseConfiguration(fileURL: url))
        for index in configuration.columns.indices {
            configuration.columns[index].mean = "999"
            if configuration.columns[index].height == 150 && configuration.columns[index].type == "Wind Speed" {
                configuration.columns[index].height = 200
            }
        }
        let summary = try NativeSummaryAnalysis.build(dataset: dataset, configuration: configuration)
        let rows = summary.sections.flatMap(\.rows)
        XCTAssertTrue(rows.contains { $0.label == "MoMM at 200 m:" && !$0.value.contains("999") })
        let measured = try XCTUnwrap(summary.charts.shear.series.first)
        XCTAssertEqual(measured.points.map(\.y).max(), 200)
        XCTAssertTrue(measured.points.allSatisfy { $0.x < 100 })
        XCTAssertEqual(rows.first { $0.label == "Mean air density:" }?.value, "n/a")
    }

    func testSummaryKeepsMissingPeriodsAsChartGaps() throws {
        let dataset = WindExportDataSet(name: "gaps", startDate: Date(timeIntervalSince1970: 1640995200),
                                        timeStepMinutes: 60, columns: [
            WindExportColumn(id: "speed", label: "Speed 80m", unit: "m/s", values: [5, nil, 7])])
        let summary = try NativeSummaryAnalysis.build(dataset: dataset)
        let months = try XCTUnwrap(summary.charts.monthly.series.first)
        XCTAssertEqual(months.points.count, 12)
        XCTAssertEqual(months.points[0].y, 6)
        XCTAssertTrue(months.points[1].y.isNaN)
        let hours = try XCTUnwrap(summary.charts.diurnal.series.first)
        XCTAssertEqual(hours.points.count, 24)
        XCTAssertTrue(hours.points[1].y.isNaN)
        XCTAssertEqual(hours.points[2].y, 7)
    }

    func testSwiftTimeSeriesMatchesStoredValuesAndCalendarPeriods() throws {
        let url = try source()
        let dataset = try WindogParser.exportDataSet(fileURL: url)
        let id = dataset.columns[0].id
        let measured = try WindogParser.parseTimeSeries(fileURL: url, channelID: id, mode: "measured")
        XCTAssertEqual(measured.points.count, 8760)
        XCTAssertEqual(measured.points[0].y, 10.756, accuracy: 0.00001)
        XCTAssertEqual(measured.points.filter { $0.y.isFinite }.count, 8753)
        XCTAssertEqual(measured.points.last?.x, Double(8759) / 24)
        let daily = try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: id, mode: "daily")
        let monthly = try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: id, mode: "monthly")
        let annual = try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: id, mode: "annual")
        XCTAssertEqual(daily.points.count, 365)
        XCTAssertEqual(monthly.points.count, 12)
        XCTAssertEqual(annual.points.count, 2)
        XCTAssertTrue(annual.points.allSatisfy { $0.y.isFinite })
        XCTAssertEqual(daily.points[0].x, 0.5)
        XCTAssertEqual(monthly.points[0].x, 15.5)
        XCTAssertThrowsError(try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: id, mode: "unknown"))
    }

    func testSwiftTimeSeriesSupportsAllListedColumnsAndConfiguredMetadata() throws {
        let dataset = WindExportDataSet(name: "test", startDate: Date(timeIntervalSince1970: 1640995200),
                                        timeStepMinutes: 60, columns: [
            WindExportColumn(id: "max", label: "Anemometer @200m;wind_speed;Max", unit: "m/s", values: [3, 9],
                             height: 200, kind: "wind_speed", subtype: "Max", colorName: "yellow"),
            WindExportColumn(id: "temperature", label: "Temperature", unit: "C", values: [-10, -5], kind: "temperature")])
        let summary = try NativeSummaryAnalysis.build(dataset: dataset)
        for channel in summary.charts.timeSeries.channels {
            let series = try NativeTimeSeriesAnalysis.series(dataset: summary.analysisData, channelID: channel.id, mode: "measured")
            XCTAssertEqual(series.points.count, 2)
        }
        XCTAssertEqual(try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: "max", mode: "daily").points[0].y, 9)
        XCTAssertEqual(try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: "temperature", mode: "measured").points[0].y, -10)
        let decoded = TimeSeriesData(decoded: summary.charts.timeSeries)
        XCTAssertEqual(decoded.startDate, dataset.startDate)
        XCTAssertEqual(decoded.endDate, dataset.startDate.addingTimeInterval(7200))
    }

    func testCurrentScreenshotFileStoredColumnsLoadInSwift() throws {
        let url = URL(fileURLWithPath: "/Users/wudong/Documents/Data/Mast/测风数据/测风塔-海上新增/8468_0273-20201201-20221130-风向矫正-异塔插补2-0.174拟合.windog")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Screenshot file unavailable") }
        let dataset = try WindogParser.exportDataSet(fileURL: url)
        XCTAssertEqual(dataset.rowCount, 730 * 144)
        let selected = dataset.columns.filter { $0.label.contains("Anemometer @100.0m A;") }
        XCTAssertEqual(selected.count, 4)
        for column in selected {
            let raw = try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: column.id, mode: "measured")
            XCTAssertEqual(raw.points.count, column.values.count)
            XCTAssertGreaterThan(raw.points.filter { $0.y.isFinite }.count, 1000)
            let day = try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: column.id, mode: "daily")
            let month = try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: column.id, mode: "monthly")
            let year = try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: column.id, mode: "annual")
            XCTAssertEqual(day.points.count, 730)
            XCTAssertEqual(month.points.count, 24)
            XCTAssertEqual(year.points.count, 3)
            XCTAssertTrue(day.points.contains { $0.y.isFinite })
            print("Screenshot column \(column.label): raw=\(raw.points.count), valid=\(raw.points.filter { $0.y.isFinite }.count), daily=\(day.points.count), monthly=\(month.points.count), annual=\(year.points.count)")
        }
    }

    private func source() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("test-data/source.windog")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local sample unavailable") }
        return url
    }

    func testApplicationReadsNativeDataAndSavesLabels() throws {
        let source = try source()
        let summary = try WindogParser.parse(fileURL: source)
        XCTAssertEqual(summary.fileName, "source.windog")
        XCTAssertFalse(summary.sections.isEmpty)
        let configuration = try WindogParser.parseConfiguration(fileURL: source)
        XCTAssertEqual(configuration.columns.count, 7)
        XCTAssertTrue(configuration.columns.contains { $0.label == "Air Density" })
        let first = try XCTUnwrap(configuration.columns.first)
        let series = try WindogParser.parseTimeSeries(fileURL: source, channelID: first.id, mode: "measured")
        XCTAssertFalse(series.points.isEmpty)
        XCTAssertEqual(series.points[0].y, 10.756, accuracy: 0.00001)
        let zeroPreview = try WindogParser.parseConfigurationPreview(fileURL: source, channelID: "Air Density")
        XCTAssertTrue(zeroPreview.pdf.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("copy.windog")
        try WindogParser.saveConfiguration(sourceURL: source, destinationURL: copy, configuration: .empty)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
        let output = directory.appendingPathComponent("edited.windog")
        var edited = DataSetConfiguration(decoded: configuration)
        edited.columns[0].label = "Renamed 150m 风速 longer than the original"
        try WindogParser.saveConfiguration(sourceURL: source, destinationURL: output, configuration: edited)
        let reopened = try WindogDocument(contentsOf: output)
        XCTAssertEqual(reopened.columns[0].name, edited.columns[0].label)
        let original = try WindogDocument(contentsOf: source)
        XCTAssertEqual(reopened.columns[4].unit, original.columns[4].unit)
        XCTAssertEqual(original.payload.subdata(in: original.columns[0].dataRange),
                       reopened.payload.subdata(in: reopened.columns[0].dataRange))
        let newConfiguration = try WindogParser.parseConfiguration(fileURL: output)
        XCTAssertEqual(newConfiguration.columns[0].label, edited.columns[0].label)

        edited.dataSet.latitude = 45
        let unsupported = directory.appendingPathComponent("unsupported.windog")
        XCTAssertThrowsError(try WindogParser.saveConfiguration(sourceURL: source, destinationURL: unsupported, configuration: edited))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsupported.path))
    }

    func testTextImportRemainsAvailableWithoutFakeNativeExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.csv")
        try "Date/Time,Speed 100m [m/s]\n2022-07-01 00:00,10\n2022-07-01 01:00,11\n".write(to: source, atomically: true, encoding: .utf8)
        let configuration = try WindogParser.parseConfiguration(fileURL: source)
        XCTAssertEqual(configuration.columns.count, 1)
        XCTAssertEqual(configuration.columns[0].unit, "m/s")
        XCTAssertThrowsError(try WindogParser.saveConfiguration(
            sourceURL: source, destinationURL: directory.appendingPathComponent("invalid.windog"),
            configuration: DataSetConfiguration(decoded: configuration)))
    }
}
