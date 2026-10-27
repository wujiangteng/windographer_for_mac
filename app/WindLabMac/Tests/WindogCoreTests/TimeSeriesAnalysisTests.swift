import XCTest
@testable import WindogCore

final class TimeSeriesAnalysisTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func data(_ values: [Double?], start: String = "2020-01-01T00:00:00Z", step: Int = 60,
                      kind: String = "wind_speed", unit: String = "m/s", id: String = "speed",
                      subtype: String = "Mean", height: Double = 200) -> WindExportDataSet {
        WindExportDataSet(name: "test", startDate: date(start), timeStepMinutes: step, columns: [
            WindExportColumn(id: id, label: id, unit: unit, values: values,
                             height: height, kind: kind, subtype: subtype)
        ])
    }

    func testMeasuredKeepsEveryPositionAndMissingBreaks() throws {
        let values: [Double?] = [4, nil, 9, .nan, .infinity, 9999, -9999, -999999, -1, 81]
        let result = try TimeSeriesAnalysis.points(dataset: data(values), columnID: "speed", mode: .measured)
        XCTAssertEqual(result.count, values.count)
        XCTAssertEqual(result[0].value, 4)
        XCTAssertEqual(result[2].value, 9)
        XCTAssertEqual(result[9].value, 81)
        for index in [1, 3, 4, 5, 6, 7, 8] {
            XCTAssertNil(result[index].value)
            XCTAssertEqual(result[index].validCount, 0)
        }
        XCTAssertEqual(result[9].timestamp, date("2020-01-01T09:00:00Z"))
    }

    func testMeasuredDoesNotDecimateAwayPeakOrLastSample() throws {
        var values = Array<Double?>(repeating: 5, count: 2401)
        values[1] = 70
        values[2399] = nil
        values[2400] = 12
        let result = try TimeSeriesAnalysis.points(dataset: data(values), columnID: "speed", mode: .measured)
        XCTAssertEqual(result.count, 2401)
        XCTAssertEqual(result[1].value, 70)
        XCTAssertNil(result[2399].value)
        XCTAssertEqual(result.last?.value, 12)
    }

    func testListedStatisticalAndHighSensorColumnsRemainLoadable() throws {
        for subtype in ["Mean", "Max", "Min", "Std. dev.", "Gust"] {
            let dataset = data([3, 4], id: "Anemometer @200m;wind_speed;\(subtype)", subtype: subtype)
            let result = try TimeSeriesAnalysis.points(dataset: dataset, columnID: dataset.columns[0].id, mode: .measured)
            XCTAssertEqual(result.compactMap(\.value), [3, 4])
        }
    }

    func testNegativeTemperatureAndVerticalSpeedAreMeasurements() throws {
        let temperature = try TimeSeriesAnalysis.points(dataset: data([-10, 0, 10, -999999], kind: "temperature", unit: "C"),
                                                        columnID: "speed", mode: .measured)
        XCTAssertEqual(temperature.prefix(3).compactMap(\.value), [-10, 0, 10])
        XCTAssertNil(temperature[3].value)
        let vertical = try TimeSeriesAnalysis.points(dataset: data([-1, 0, 1, -999999], kind: "vertical_wind_speed"),
                                                     columnID: "speed", mode: .measured)
        XCTAssertEqual(vertical.prefix(3).compactMap(\.value), [-1, 0, 1])
        XCTAssertNil(vertical[3].value)
    }

    func testMeasuredDirectionAccepts360AndRejectsOutOfRange() throws {
        let result = try TimeSeriesAnalysis.points(dataset: data([0, 360, 361, -1, 9999], kind: "wind_direction", unit: "deg"),
                                                   columnID: "speed", mode: .measured)
        XCTAssertNotNil(result[0].value)
        XCTAssertNotNil(result[1].value)
        XCTAssertTrue(result.dropFirst(2).allSatisfy { $0.value == nil })
    }

    func testDailyKeepsEntireMissingCalendarDay() throws {
        let values = Array<Double?>(repeating: 6, count: 24)
            + Array<Double?>(repeating: nil, count: 24)
            + Array<Double?>(repeating: 10, count: 24)
        let result = try TimeSeriesAnalysis.points(dataset: data(values), columnID: "speed", mode: .daily)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].value, 6)
        XCTAssertEqual(result[0].validCount, 24)
        XCTAssertNil(result[1].value)
        XCTAssertEqual(result[1].validCount, 0)
        XCTAssertEqual(result[2].value, 10)
    }

    func testLeapMonthCalendarBinsRemainDistinct() throws {
        let values = Array<Double?>(repeating: 2, count: 31 * 24)
            + Array<Double?>(repeating: 4, count: 29 * 24)
        let result = try TimeSeriesAnalysis.points(dataset: data(values), columnID: "speed", mode: .monthly)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].value, 2)
        XCTAssertEqual(result[0].validCount, 31 * 24)
        XCTAssertEqual(result[1].value, 4)
        XCTAssertEqual(result[1].validCount, 29 * 24)
    }

    func testMonthlyKeepsMissingMonthBetweenAvailableMonths() throws {
        let values = Array<Double?>(repeating: 2, count: 31 * 24)
            + Array<Double?>(repeating: nil, count: 29 * 24)
            + Array<Double?>(repeating: 6, count: 31 * 24)
        let result = try TimeSeriesAnalysis.points(dataset: data(values), columnID: "speed", mode: .monthly)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].value, 2)
        XCTAssertNil(result[1].value)
        XCTAssertEqual(result[2].value, 6)
    }

    func testAnnualDoesNotPoolDifferentYears() throws {
        let values = Array<Double?>(repeating: 1, count: 366 * 24)
            + Array<Double?>(repeating: 3, count: 365 * 24)
        let result = try TimeSeriesAnalysis.points(dataset: data(values), columnID: "speed", mode: .annual)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].value, 1)
        XCTAssertEqual(result[0].validCount, 366 * 24)
        XCTAssertEqual(result[1].value, 3)
        XCTAssertEqual(result[1].validCount, 365 * 24)
    }

    func testDailyRecoveryThresholdIncludesEquality() throws {
        for (count, accepted) in [(17, false), (18, true)] {
            let values = Array<Double?>(repeating: 8, count: count)
                + Array<Double?>(repeating: nil, count: 24 - count)
            let points = try TimeSeriesAnalysis.points(dataset: data(values), columnID: "speed", mode: .daily)
            XCTAssertEqual(points.count, 1)
            XCTAssertEqual(points[0].value != nil, accepted)
            XCTAssertEqual(points[0].validCount, count)
            if accepted { XCTAssertEqual(points[0].value, 8) }
        }
    }

    func testMonthlyAndAnnualRecoveryThresholdsIncludeEquality() throws {
        let cases: [(WindTimeSeriesMode, String, Int, Int)] = [
            (.monthly, "2021-04-01T00:00:00Z", 30 * 24, 576),
            (.annual, "2021-01-01T00:00:00Z", 365 * 24, 7884)
        ]
        for (mode, start, total, minimum) in cases {
            for count in [minimum - 1, minimum] {
                let values = Array<Double?>(repeating: 7, count: count)
                    + Array<Double?>(repeating: nil, count: total - count)
                let points = try TimeSeriesAnalysis.points(dataset: data(values, start: start), columnID: "speed", mode: mode)
                XCTAssertEqual(points.count, 1)
                XCTAssertEqual(points[0].value != nil, count == minimum)
                XCTAssertEqual(points[0].validCount, count)
            }
        }
    }

    func testPartialMonthRecoveryDenominatorStopsAtFileBounds() throws {
        let values = Array<Double?>(repeating: 5, count: 8) + [nil, nil]
        let points = try TimeSeriesAnalysis.points(dataset: data(values, start: "2020-01-31T14:00:00Z"),
                                                   columnID: "speed", mode: .monthly)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].value, 5)
        XCTAssertEqual(points[0].validCount, 8)
        let failed = try TimeSeriesAnalysis.points(dataset: data(Array(values.dropFirst()), start: "2020-01-31T15:00:00Z"),
                                                   columnID: "speed", mode: .monthly)
        XCTAssertNil(failed[0].value)
    }

    func testDailyFractionalOverlapUsesPartialSourceIntervals() throws {
        let points = try TimeSeriesAnalysis.points(dataset: data([2, 8], start: "2020-01-01T23:30:00Z"),
                                                   columnID: "speed", mode: .daily)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].value, 2)
        XCTAssertEqual(try XCTUnwrap(points[1].value), 6, accuracy: 1e-12)
        XCTAssertEqual(points[0].validCount, 1)
        XCTAssertEqual(points[1].validCount, 2)
        XCTAssertEqual(points[0].timestamp, date("2020-01-01T12:00:00Z"))
        XCTAssertEqual(points[1].timestamp, date("2020-01-02T12:00:00Z"))
    }

    func testDailySubtypeAggregatesDifferFromMonthlyArithmeticMean() throws {
        let values = Array<Double?>(repeating: 3, count: 12) + Array<Double?>(repeating: 4, count: 12)
        let expected: [(String, Double)] = [("Min", 3), ("Max", 4), ("Gust", 3.5), ("Std. dev.", sqrt(12.5)), ("Mean", 3.5)]
        for (subtype, value) in expected {
            let dataset = data(values, subtype: subtype)
            let daily = try TimeSeriesAnalysis.points(dataset: dataset, columnID: "speed", mode: .daily)
            let monthly = try TimeSeriesAnalysis.points(dataset: dataset, columnID: "speed", mode: .monthly)
            XCTAssertEqual(try XCTUnwrap(daily[0].value), value, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(monthly[0].value), 3.5, accuracy: 1e-12)
        }
    }

    func testDirectionMeansUseAssociatedSpeedWeightsAndUnitVectorFallback() throws {
        let direction = WindExportColumn(id: "direction", label: "Direction 100m", unit: "deg", values: [0, 90],
                                         height: 100, kind: "wind_direction", subtype: "Mean", associatedSpeedID: "speed")
        let speed = WindExportColumn(id: "speed", label: "Speed 100m", unit: "m/s", values: [1, 3],
                                     height: 100, kind: "wind_speed", subtype: "Mean")
        let dataset = WindExportDataSet(name: "vectors", startDate: date("2020-01-01T00:00:00Z"),
                                        timeStepMinutes: 60, columns: [direction, speed])
        for mode in [WindTimeSeriesMode.daily, .monthly, .annual] {
            let points = try TimeSeriesAnalysis.points(dataset: dataset, columnID: "direction", mode: mode)
            XCTAssertEqual(try XCTUnwrap(points[0].value), atan2(3, 1) * 180 / .pi, accuracy: 1e-10)
        }
        let unweighted = try TimeSeriesAnalysis.points(dataset: data([359, 1], kind: "wind_direction", unit: "deg"),
                                                       columnID: "speed", mode: .daily)
        XCTAssertEqual(try XCTUnwrap(unweighted[0].value), 0, accuracy: 1e-10)
    }

    func testInvalidPairedSpeedCountsAgainstDirectionRecovery() throws {
        let direction = WindExportColumn(id: "direction", label: "Direction", unit: "deg", values: [0, 90, 180, 270],
                                         kind: "wind_direction", subtype: "Mean", associatedSpeedID: "speed")
        for (speeds, accepted, validCount) in [([1.0, nil, 1.0, nil], false, 2), ([1.0, 1.0, 1.0, nil], true, 3)] {
            let speed = WindExportColumn(id: "speed", label: "Speed", unit: "m/s", values: speeds,
                                         kind: "wind_speed", subtype: "Mean")
            let dataset = WindExportDataSet(name: "pairs", startDate: date("2020-01-01T00:00:00Z"),
                                            timeStepMinutes: 60, columns: [direction, speed])
            let points = try TimeSeriesAnalysis.points(dataset: dataset, columnID: "direction", mode: .daily)
            XCTAssertEqual(points[0].value != nil, accepted)
            XCTAssertEqual(points[0].validCount, validCount)
            if accepted { XCTAssertEqual(try XCTUnwrap(points[0].value), 90, accuracy: 1e-10) }
        }
    }

    func testMonthlyPointsUseCalendarPeriodCenters() throws {
        let values = Array<Double?>(repeating: 2, count: (31 + 29) * 24)
        let points = try TimeSeriesAnalysis.points(dataset: data(values), columnID: "speed", mode: .monthly)
        XCTAssertEqual(points[0].timestamp, date("2020-01-16T12:00:00Z"))
        XCTAssertEqual(points[1].timestamp, date("2020-02-15T12:00:00Z"))
    }

    func testMissingColumnAndBadDatasetFailExplicitly() throws {
        XCTAssertThrowsError(try TimeSeriesAnalysis.points(dataset: data([1]), columnID: "missing", mode: .measured))
        XCTAssertThrowsError(try TimeSeriesAnalysis.points(dataset: data([1], step: 0), columnID: "speed", mode: .daily))
    }
}
