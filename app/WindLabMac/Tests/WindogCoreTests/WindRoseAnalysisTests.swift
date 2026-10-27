import XCTest
@testable import WindogCore

final class WindRoseAnalysisTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func dataset(directions: [Double?], data: [Double?]? = nil, bin: [Double?]? = nil,
                         calm: Double? = nil, start: String = "2020-01-01T00:00:00Z", step: Int = 60,
                         dataKind: String = "wind_speed", dataUnit: String = "m/s") -> WindExportDataSet {
        var columns = [WindExportColumn(id: "direction", label: "Direction 100m", unit: "deg", values: directions,
                                        height: 100, kind: "wind_direction", subtype: "Mean")]
        if let data { columns.append(WindExportColumn(id: "data", label: "Data 100m", unit: dataUnit,
                                                      values: data, height: 100, kind: dataKind, subtype: "Mean")) }
        if let bin { columns.append(WindExportColumn(id: "bin", label: "Bin", unit: "C", values: bin, kind: "temperature")) }
        return WindExportDataSet(name: "test", startDate: date(start), timeStepMinutes: step,
                                 columns: columns, metadata: calm.map { WindSummaryMetadata(calmThreshold: $0) })
    }

    func testNorthCenteredSectorsWrap360AndRespectBoundary() throws {
        let result = try WindRoseAnalysis.analyze(dataset(directions: [0, 360, 44.9, 45, 90, 180, 270]),
            request: RoseRequest(sectors: 4))
        XCTAssertEqual(result.sectorCenters, [0, 90, 180, 270])
        XCTAssertEqual(result.series[0].counts, [3, 2, 1, 1])
        XCTAssertEqual(result.series[0].sectorValues.compactMap { $0 }, [3, 2, 1, 1])
    }

    func testAllDirectionsFrequencyRetainsCalmsInDenominator() throws {
        let result = try WindRoseAnalysis.analyze(dataset(directions: [0, 90, 180, 360], data: [0, 2, nil, 3], calm: 1),
            request: RoseRequest(display: .frequency, sectors: 4))
        XCTAssertEqual(result.series[0].validCount, 3)
        XCTAssertEqual(result.series[0].calmCount, 1)
        XCTAssertEqual(result.series[0].counts, [1, 1, 0, 0])
        XCTAssertEqual(result.series[0].sectorValues.compactMap { $0 }.reduce(0, +), 200.0 / 3, accuracy: 1e-10)
        XCTAssertEqual(result.overallValidCount, 3)
        XCTAssertEqual(result.calmCount, 1)
    }

    func testGenericDirectionCountsIncludeCalmsAndRequireDataPairs() throws {
        let result = try WindRoseAnalysis.analyze(dataset(directions: [0, 90, 180, 360], data: [0, 2, nil, 3], calm: 1),
            request: RoseRequest(directionID: "direction", dataIDs: ["data"], grouping: .direction, display: .frequency, sectors: 4))
        XCTAssertEqual(result.series[0].validCount, 3)
        XCTAssertEqual(result.series[0].calmCount, 0)
        XCTAssertEqual(result.series[0].counts, [2, 1, 0, 0])
        XCTAssertEqual(result.series[0].sectorValues.compactMap { $0 }.reduce(0, +), 100, accuracy: 1e-10)
    }

    func testGenericMeanMinMaxAndSampleStandardDeviation() throws {
        let data = dataset(directions: [0, 0, 90], data: [1, 3, 7])
        let expected: [(RoseDisplay, Double)] = [(.mean, 2), (.minimum, 1), (.maximum, 3), (.standardDeviation, sqrt(2))]
        for (display, value) in expected {
            let result = try WindRoseAnalysis.analyze(data, request: RoseRequest(directionID: "direction", dataIDs: ["data"],
                grouping: .direction, display: display, sectors: 4))
            XCTAssertEqual(try XCTUnwrap(result.series[0].sectorValues[0]), value, accuracy: 1e-10)
            XCTAssertNil(result.series[0].sectorValues[2])
            if display == .standardDeviation { XCTAssertEqual(result.series[0].sectorValues[1], 0) }
        }
    }

    func testMonthGroupingPoolsYearsOverridesMonthAndKeepsEmptyGroups() throws {
        let data = dataset(directions: [0, 90, 180], data: [1, 2, 3], start: "2020-01-31T00:00:00Z", step: 1440)
        let result = try WindRoseAnalysis.analyze(data, request: RoseRequest(directionID: "direction", dataIDs: ["data"],
            grouping: .month, display: .frequency, sectors: 4, selection: .init(month: 1)))
        XCTAssertEqual(result.series.count, 12)
        XCTAssertEqual(result.series[0].label, "Jan")
        XCTAssertEqual(result.series[0].validCount, 1)
        XCTAssertEqual(result.series[1].validCount, 2)
        XCTAssertEqual(result.series[1].sectorValues.compactMap { $0 }.reduce(0, +), 100)
        XCTAssertEqual(result.series[2].sectorValues.compactMap { $0 }, [0, 0, 0, 0])
    }

    func testHourGroupingUsesNativeTwoHourIntervals() throws {
        let data = dataset(directions: [0, 90, 180, 270], data: [1, 2, 3, 4])
        let result = try WindRoseAnalysis.analyze(data, request: RoseRequest(directionID: "direction", dataIDs: ["data"],
            grouping: .hour, display: .occurrences, sectors: 4))
        XCTAssertEqual(result.series.count, 12)
        XCTAssertEqual(result.series[0].label, "00:00 – 02:00")
        XCTAssertEqual(result.series[0].counts, [1, 1, 0, 0])
        XCTAssertEqual(result.series[1].counts, [0, 0, 1, 1])
        XCTAssertEqual(result.series[11].label, "22:00 – 24:00")
    }

    func testBinFrequencyUsesAllValidTripletsEvenBelowCustomStart() throws {
        let data = dataset(directions: [0, 90, 180], data: [1, 2, 3], bin: [0, 1, 2])
        let result = try WindRoseAnalysis.analyze(data, request: RoseRequest(directionID: "direction", dataIDs: ["data"],
            grouping: .bin, display: .frequency, sectors: 4, binID: "bin", bins: .init(width: 1, start: 1)))
        XCTAssertEqual(result.series.count, 1)
        XCTAssertEqual(result.series[0].counts, [0, 1, 1, 0])
        XCTAssertEqual(result.series[0].sectorValues.compactMap { $0 }.reduce(0, +), 200.0 / 3, accuracy: 1e-10)
        XCTAssertEqual(result.overallValidCount, 3)
    }

    func testBinAutoGridUsesNativeTwentyToFortyTarget() throws {
        let values = (0..<100).map { Double($0) / 10 }
        let data = dataset(directions: values.map { _ in 0 }, data: values.map(Optional.some), bin: values.map(Optional.some))
        let result = try WindRoseAnalysis.analyze(data, request: RoseRequest(directionID: "direction", dataIDs: ["data"],
            grouping: .bin, display: .occurrences, sectors: 16, binID: "bin"))
        XCTAssertTrue((20...40).contains(result.series.count))
        XCTAssertEqual(result.series.flatMap(\.counts).reduce(0, +), 100)
    }

    func testEnergyUsesStoredPowerDensityWhenAvailable() throws {
        let base = dataset(directions: [0, 90], data: [1, 2])
        let power = WindExportColumn(id: "power", label: "WPD 100m", unit: "W/m2", values: [9, 1],
                                    height: 100, kind: "power_density", subtype: "Mean", associatedSpeedID: "data")
        let data = WindExportDataSet(name: base.name, startDate: base.startDate, timeStepMinutes: 60,
                                     columns: base.columns + [power])
        let result = try WindRoseAnalysis.analyze(data, request: RoseRequest(directionID: "direction", dataIDs: ["data"],
            grouping: .direction, display: .totalEnergy, sectors: 4))
        XCTAssertEqual(result.series[0].sectorValues.compactMap { $0 }, [90, 10, 0, 0])
        XCTAssertFalse(result.notes.contains { $0.contains("speed³") })
    }

    func testEnergyFallbackIsLabeledConstantDensityEstimate() throws {
        let result = try WindRoseAnalysis.analyze(dataset(directions: [0, 90], data: [1, 2]),
            request: RoseRequest(directionID: "direction", dataIDs: ["data"], grouping: .direction, display: .totalEnergy, sectors: 4))
        XCTAssertEqual(try XCTUnwrap(result.series[0].sectorValues[0]), 100.0 / 9, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(result.series[0].sectorValues[1]), 800.0 / 9, accuracy: 1e-10)
        XCTAssertTrue(result.notes.contains { $0.contains("constant-density") })
    }

    func testScatterRetainsRawPairsNegativeValuesAndFilters() throws {
        let data = dataset(directions: [0, 90, 180, 360], data: [-10, -5, 0, -999999],
                           dataKind: "temperature", dataUnit: "C")
        let result = try WindRoseAnalysis.analyze(data, request: RoseRequest(directionID: "direction", dataIDs: ["data"],
            grouping: .direction, display: .scatter, sectors: 4, selection: .init(includedIndices: [0, 2, 3])))
        XCTAssertEqual(result.series[0].scatterPoints.map(\.direction), [0, 180])
        XCTAssertEqual(result.series[0].scatterPoints.map(\.value), [-10, 0])
        XCTAssertTrue(result.series[0].sectorValues.allSatisfy { $0 == nil })
        XCTAssertEqual(result.series[0].unit, "C")
    }

    func testAllDirectionComparisonOnlyIncludesMeanDirectionSensors() throws {
        let base = dataset(directions: [0])
        let excluded = WindExportColumn(id: "maximum", label: "Direction Max", unit: "deg", values: [90],
                                        kind: "wind_direction", subtype: "Max")
        let data = WindExportDataSet(name: base.name, startDate: base.startDate, timeStepMinutes: 60, columns: base.columns + [excluded])
        let result = try WindRoseAnalysis.analyze(data, request: RoseRequest())
        XCTAssertEqual(result.series.map(\.id), ["direction"])
    }

    func testArbitrarySectorCountsAndInvalidRequests() throws {
        let data = dataset(directions: [0, 360], data: [1, 2])
        let result = try WindRoseAnalysis.analyze(data, request: RoseRequest(sectors: 7))
        XCTAssertEqual(result.sectorCenters.count, 7)
        XCTAssertEqual(result.series[0].counts[0], 2)
        XCTAssertThrowsError(try WindRoseAnalysis.analyze(data, request: RoseRequest(sectors: 3)))
        XCTAssertThrowsError(try WindRoseAnalysis.analyze(data, request: RoseRequest(grouping: .allDirections, display: .mean)))
        XCTAssertThrowsError(try WindRoseAnalysis.analyze(data, request: RoseRequest(dataIDs: ["missing"], grouping: .direction)))
        XCTAssertThrowsError(try WindRoseAnalysis.analyze(data, request: RoseRequest(grouping: .direction, display: .mean)))
        XCTAssertThrowsError(try WindRoseAnalysis.analyze(data, request: RoseRequest(dataIDs: ["data"], grouping: .hour, display: .totalEnergy)))
    }
}
