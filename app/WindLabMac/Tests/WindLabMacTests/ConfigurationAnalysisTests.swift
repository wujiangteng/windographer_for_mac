import XCTest
import WindogCore
@testable import WindLabMac

final class ConfigurationAnalysisTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z")!

    func testMonthlyBoxesUseMeanDailyExtremaRatherThanQuartiles() throws {
        // Day1 has min0 max10 mean5. Day2 min100 max100; raw mean differs
        // from a mean of daily means because valid sample counts differ.
        let values: [Double?] = [0, 10] + Array(repeating: nil, count: 22) + [100]
        let data = WindExportDataSet(name: "boxes", startDate: start, timeStepMinutes: 60,
            columns: [WindExportColumn(id: "x", label: "x", unit: "V", values: values)])
        let preview = try NativeConfigurationAnalysis.preview(dataset: data, channelID: "x")
        let january = try XCTUnwrap(preview.monthly.first)
        XCTAssertEqual(january.min, 0)
        XCTAssertEqual(january.max, 100)
        XCTAssertEqual(january.mean, 110.0 / 3, accuracy: 1e-10)
        XCTAssertEqual(january.q1, 50) // mean of 0 and100, not25thpercentile
        XCTAssertEqual(january.q3, 55) // mean of10 and100, not75thpercentile
        XCTAssertEqual(preview.pdf.reduce(0) { $0 + $1.y }, 100, accuracy: 1e-10)
        XCTAssertTrue((15...40).contains(preview.pdf.count))
    }

    func testPreviewUsesEverySampleRatherThanSteppedFiveThousandSubset() throws {
        var values = Array<Double?>(repeating: 0, count: 10_001)
        values[1] = 100
        values[10_000] = 9999
        let data = WindExportDataSet(name: "sampling", startDate: start, timeStepMinutes: 10,
            columns: [WindExportColumn(id: "x", label: "Temperature", unit: "C", values: values)])
        let preview = try NativeConfigurationAnalysis.preview(dataset: data, channelID: "x")
        XCTAssertEqual(preview.pdf.reduce(0) { $0 + $1.y }, 100, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(preview.monthly.first).max, 100)
        XCTAssertEqual(NativeConfigurationAnalysis.statistics(column: data.columns[0]).mean!, 0.01, accuracy: 1e-12)
    }

    func testConfigurationRetainsEmptyAndShortColumnsAndUnambiguousCompanions() throws {
        let columns = [
            WindExportColumn(id: "a", label: "Anemometer @100m A;Avg", unit: "m/s", values: [1,2,3], height: 100, kind: "wind_speed", subtype: "Mean"),
            WindExportColumn(id: "amax", label: "Anemometer @100m A;Max", unit: "m/s", values: [4], height: 100, kind: "wind_speed", subtype: "Max"),
            WindExportColumn(id: "bmax", label: "Anemometer @100m B;Max", unit: "m/s", values: [], height: 100, kind: "wind_speed", subtype: "Max")]
        let data = WindExportDataSet(name: "columns", startDate: start, timeStepMinutes: 10, columns: columns)
        let config = NativeConfigurationAnalysis.configuration(dataset: data)
        XCTAssertEqual(config.columns.count, 3)
        XCTAssertEqual(config.columns[0].associated.max, "amax")
        XCTAssertEqual(config.columns[2].mean, "-")
        XCTAssertTrue(try NativeConfigurationAnalysis.preview(dataset: data, channelID: "bmax").pdf.isEmpty)
    }

    func testNegativeRawValuesAndDirectionMeansAreNotReplacedByQualityFiltering() {
        let column = WindExportColumn(id: "x", label: "Direction", unit: "deg", values: [-1, 1, 359, nil, .nan, 9999], kind: "wind_direction")
        let stats = NativeConfigurationAnalysis.statistics(column: column)
        XCTAssertEqual(stats.mean!, 359.0 / 3, accuracy: 1e-10)
        XCTAssertEqual(stats.minimum, -1)
    }
    func testScreenshotTextRoseUsesFourVaryingSensorsRatherThanCoordinates() throws {
        let url = URL(fileURLWithPath: "/Users/wudong/Documents/Data/Mast/测风数据/测风塔-深远海/20057-12185_02_0201_1723187150381_06 1901&1902-完整年选B通道-Exported.txt")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("User screenshot file unavailable") }
        let dataset = try WindogParser.exportDataSet(fileURL: url)
        XCTAssertEqual(dataset.rowCount, 52704)
        for name in ["N", "E"] {
            let coordinate = try XCTUnwrap(dataset.columns.first { $0.label == name })
            XCTAssertEqual(coordinate.kind, "other")
            XCTAssertEqual(Set(coordinate.values.compactMap { $0 }).count, 1)
        }
        let summary = try SummaryStatistics.analyze(dataset)
        XCTAssertEqual(Set(summary.roses.map(\.label)), ["WD_100m_Avg", "WD_50m_Avg", "WD_100m_B_Avg", "WD_23m_B_Avg"])
        for rose in summary.roses {
            XCTAssertGreaterThan(rose.validCount, 50000)
            XCTAssertLessThan(try XCTUnwrap(rose.points.map(\.fraction).max()), 0.5)
            XCTAssertGreaterThan(rose.points.filter { $0.fraction > 0 }.count, 12)
        }
    }
    func testGenericMetadataColumnsDoNotAcquireUnrelatedSensorAssociations() {
        let dataset = WindExportDataSet(name: "metadata", startDate: Date(timeIntervalSince1970: 0), timeStepMinutes: 10,
            columns: [WindExportColumn(id: "record", label: "RECORD", unit: "RN", values: [1,2], kind: "other"),
                WindExportColumn(id: "voltage", label: "Batt_Volt_Std", unit: "V", values: [0.1,0.2], kind: "other", subtype: "Std. dev.")])
        let configuration = NativeConfigurationAnalysis.configuration(dataset: dataset)
        XCTAssertEqual(configuration.columns[0].associated.stdDev, "<none>")
    }
}
