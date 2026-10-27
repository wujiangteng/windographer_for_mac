import XCTest
@testable import WindogCore

final class SummaryStatisticsTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func column(_ id: String, _ values: [Double?], height: Double? = nil,
                        kind: String = "wind_speed", unit: String = "m/s") -> WindExportColumn {
        WindExportColumn(id: id, label: id, unit: unit, values: values, height: height, kind: kind, subtype: "Mean")
    }

    private func data(_ columns: [WindExportColumn], start: String = "2022-01-01T00:00:00Z", step: Int = 60,
                      metadata: WindSummaryMetadata? = nil) -> WindExportDataSet {
        WindExportDataSet(name: "test", startDate: date(start), timeStepMinutes: step, columns: columns, metadata: metadata)
    }

    func testCalendarPoolingPreservesMissingMonthsAndHourlyGaps() throws {
        var values = Array<Double?>(repeating: nil, count: 366)
        values[0] = 2
        values[365] = 6
        let result = try SummaryStatistics.analyze(data([column("speed", values)], step: 1440))
        let stats = try XCTUnwrap(result.columns.first)
        XCTAssertEqual(stats.monthly.count, 12)
        XCTAssertEqual(stats.monthly[0].mean, 4)
        XCTAssertEqual(stats.monthly[0].count, 2)
        XCTAssertNil(stats.monthly[1].mean)
        XCTAssertEqual(stats.hourly.count, 24)
        XCTAssertEqual(stats.hourly[0].mean, 4)
        XCTAssertNil(stats.hourly[1].mean)
        XCTAssertEqual(result.endDate, date("2023-01-01T00:00:00Z"))
        XCTAssertEqual(result.coverageEndDate, date("2023-01-02T00:00:00Z"))
    }

    func testFractionalCompletenessIsDefaultMoMMPolicy() throws {
        var values = Array<Double?>(repeating: nil, count: 32)
        values[0] = 10; values[1] = 10; values[31] = 30
        let dataset = data([column("speed", values, height: 150)], step: 1440)
        let weighted = try SummaryStatistics.analyze(dataset)
        let binary = try SummaryStatistics.analyze(dataset, availabilityWeightedMoMM: false)
        XCTAssertEqual(try XCTUnwrap(weighted.meanAtHighestHeight), 50 / 3, accuracy: 1e-10)
        let februaryDays = Double(Float(28.24))
        XCTAssertEqual(try XCTUnwrap(binary.meanAtHighestHeight), (10 * 31 + 30 * februaryDays) / (31 + februaryDays), accuracy: 1e-10)
    }

    func testShearUsesOnlyConcurrentSamples() throws {
        let result = try SummaryStatistics.analyze(data([
            column("low", [1, 100, nil], height: 10),
            column("high", [2, nil, 200], height: 20)
        ]))
        XCTAssertEqual(result.shear.measured.map(\.speed), [1, 2])
        XCTAssertEqual(try XCTUnwrap(result.shear.powerExponent), 1, accuracy: 1e-12)
        let disjoint = try SummaryStatistics.analyze(data([
            column("low", [1, nil], height: 10), column("high", [nil, 2], height: 20)
        ]))
        XCTAssertTrue(disjoint.shear.measured.isEmpty)
        XCTAssertNil(disjoint.shear.powerExponent)
    }

    func testLogRegressionKeepsNegativeLogHeightsAndZeroLogSpeeds() throws {
        let result = try SummaryStatistics.analyze(data([
            column("low", [1], height: 0.5), column("high", [2], height: 1)
        ]))
        XCTAssertEqual(try XCTUnwrap(result.shear.powerExponent), 1, accuracy: 1e-12)
        XCTAssertEqual(result.shear.powerCurve.first?.height, 0.5)
    }

    func testDuplicateHeightsCannotDefineShear() throws {
        let result = try SummaryStatistics.analyze(data([
            column("sensorA", [5], height: 50), column("sensorB", [6], height: 50)
        ]))
        XCTAssertNil(result.shear.powerExponent)
        XCTAssertNil(result.shear.roughnessLength)
        XCTAssertTrue(result.shear.measured.isEmpty)
    }

    func testMalformedRoseAssociationCannotUseAnUnknownUnitAsSpeed() throws {
        let direction = WindExportColumn(id: "direction", label: "direction", unit: "deg", values: [0, 90],
                                         height: 50, kind: "wind_direction", subtype: "Mean", associatedSpeedID: "badSpeed")
        let result = try SummaryStatistics.analyze(data([
            direction, column("badSpeed", [0, nil], height: 50, unit: "unknown"),
            column("goodSpeed", [2, 2], height: 50)
        ], metadata: WindSummaryMetadata(calmThreshold: 1)))
        let rose = try XCTUnwrap(result.roses.first)
        XCTAssertEqual(rose.associatedSpeedID, "goodSpeed")
        XCTAssertEqual(rose.validCount, 2)
        XCTAssertEqual(rose.calmCount, 0)
    }

    func testRoseNorthWrapAndCalmDenominator() throws {
        let result = try SummaryStatistics.analyze(data([
            column("speed", [0, 2, 3, 2, nil, 4], height: 150),
            column("direction", [360, 0, 90, 180, 270, 9999], height: 150, kind: "wind_direction", unit: "deg")
        ], metadata: WindSummaryMetadata(calmThreshold: 1)))
        let rose = try XCTUnwrap(result.roses.first)
        XCTAssertEqual(rose.associatedSpeedID, "speed")
        XCTAssertEqual(rose.validCount, 4)
        XCTAssertEqual(rose.calmCount, 1)
        XCTAssertEqual(rose.points[0].fraction, 0.25)
        XCTAssertEqual(rose.points[4].fraction, 0.25)
        XCTAssertEqual(rose.points[8].fraction, 0.25)
        XCTAssertEqual(rose.points.reduce(0) { $0 + $1.fraction }, 0.75)
    }

    func testPowerAt50RequiresActualPowerDensityHeightModel() throws {
        let unsupported = try SummaryStatistics.analyze(data([
            column("speed", [10], height: 150),
            column("power", [900], height: 150, kind: "power_density", unit: "W/m2")
        ]))
        XCTAssertNil(unsupported.powerDensityAt50)
        XCTAssertNil(unsupported.powerClass)
        let model = try SummaryStatistics.analyze(data([
            column("power25", [100], height: 25, kind: "power_density", unit: "W/m2"),
            column("power100", [400], height: 100, kind: "power_density", unit: "W/m2")
        ]))
        XCTAssertEqual(try XCTUnwrap(model.powerDensityAt50), 200, accuracy: 1e-10)
        let direct = try SummaryStatistics.analyze(data([
            column("power50", [300], height: 50, kind: "power_density", unit: "W/m2")
        ]))
        XCTAssertEqual(direct.powerDensityAt50, 300)
        XCTAssertEqual(direct.powerClass, 3)
        let unknownUnits = try SummaryStatistics.analyze(data([
            column("unknownPower", [300], height: 50, kind: "power_density", unit: "unknown")
        ]))
        XCTAssertNil(unknownUnits.powerDensityAt50)
        let inferredColumn = WindExportColumn(id: "wpd", label: "150m功率密度", unit: "", values: [300],
                                             height: 50, kind: "power_density", subtype: "Mean")
        let inferred = try SummaryStatistics.analyze(data([inferredColumn]))
        XCTAssertEqual(inferred.powerDensityAt50, 300)
    }

    func testEnvironmentIsNotFabricatedWithoutElevationOrMeasurements() throws {
        let dataset = data([column("speed", [5])])
        let result = try SummaryStatistics.analyze(dataset)
        XCTAssertNil(result.temperature)
        XCTAssertNil(result.pressure)
        XCTAssertNil(result.density)
        XCTAssertNil(result.densityRatio)
        let fallback = try SummaryStatistics.analyze(data(dataset.columns, metadata: WindSummaryMetadata(elevation: 0)))
        XCTAssertEqual(fallback.temperature, 15)
        XCTAssertEqual(fallback.pressure, 101.325)
        XCTAssertNil(fallback.density)
    }

    func testHighestEnvironmentMeasurementsAndUnitConversions() throws {
        let result = try SummaryStatistics.analyze(data([
            column("tempLow", [15], height: 10, kind: "temperature", unit: "C"),
            column("tempHigh", [-5, -7], height: 100, kind: "temperature", unit: "C"),
            column("pressure", [1000], height: 100, kind: "pressure", unit: "hPa"),
            column("rho", [1.225], height: 100, kind: "density", unit: "kg/m3")
        ]))
        XCTAssertEqual(result.temperature, -6)
        XCTAssertEqual(result.pressure, 100)
        XCTAssertEqual(result.densityRatio, 1)
    }

    func testValidityAndEligibleUnits() throws {
        let result = try SummaryStatistics.analyze(data([
            column("speed", [90, -1, 9999, .infinity, nil], height: 100),
            column("unknownUnit", [100], height: 200, unit: "unknown"),
            column("direction", [90], kind: "wind_direction", unit: "unknown")
        ]))
        XCTAssertEqual(result.columns[0].validCount, 1)
        XCTAssertEqual(result.columns[0].mean, 90)
        XCTAssertEqual(result.highestSpeedColumnID, "speed")
        XCTAssertTrue(result.roses.isEmpty)
        XCTAssertEqual(result.storedValueCount, 7)
    }
}
