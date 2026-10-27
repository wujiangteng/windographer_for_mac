import XCTest
@testable import WindogCore

final class HistogramAnalysisTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func dataset(_ values: [Double?], secondary: [Double?]? = nil, start: String = "2020-01-01T00:00:00Z",
                         step: Int = 60, kind: String = "wind_speed", unit: String = "m/s") -> WindExportDataSet {
        var columns = [WindExportColumn(id: "primary", label: "Primary", unit: unit, values: values, kind: kind)]
        if let secondary { columns.append(WindExportColumn(id: "secondary", label: "Other", unit: "m/s", values: secondary, kind: "wind_speed")) }
        return WindExportDataSet(name: "test", startDate: date(start), timeStepMinutes: step, columns: columns)
    }

    func testSharedCountsSupplyFrequenciesAndOccurrences() throws {
        let result = try HistogramAnalysis.analyze(dataset([0, 0.5, 1, 1.5, 2]), request: HistogramRequest(
            primaryID: "primary", primaryBins: .init(width: 0.5, start: 0)))
        XCTAssertEqual(result.sampleCount, 5)
        XCTAssertEqual(result.includedCount, 5)
        XCTAssertEqual(result.counts.map { $0[0] }, [1, 1, 1, 2])
        XCTAssertEqual(result.percentages.map { $0[0] }, [20, 20, 20, 40])
        XCTAssertEqual(result.groupTotals, [5])
    }

    func testHalfFirstBinInteriorAndFinalEdges() throws {
        let result = try HistogramAnalysis.analyze(dataset([0, 0.5, 1, 1.5, 2]), request: HistogramRequest(
            primaryID: "primary", primaryBins: .init(width: 1, start: 0, halfFirst: true)))
        XCTAssertEqual(result.bins.map(\.lower), [0, 0.5, 1.5])
        XCTAssertEqual(result.bins.map(\.upper), [0.5, 1.5, 2.5])
        XCTAssertEqual(result.counts.map { $0[0] }, [1, 2, 2])
    }

    func testOneDimensionalCustomStartRenormalizesBinnedSamples() throws {
        let result = try HistogramAnalysis.analyze(dataset([0, 1, 2, 3]), request: HistogramRequest(
            primaryID: "primary", primaryBins: .init(width: 1, start: 1)))
        XCTAssertEqual(result.sampleCount, 4)
        XCTAssertEqual(result.includedCount, 3)
        XCTAssertEqual(result.normalizationCount, 3)
        XCTAssertEqual(result.percentages.flatMap { $0 }.reduce(0, +), 100)
        XCTAssertEqual(result.primaryValues, [0, 1, 2, 3])
    }

    func testPooledMonthsRetainAllTwelveGroupsAndMissingMonthZeros() throws {
        var values = Array<Double?>(repeating: nil, count: 367)
        values[0] = 1
        values[366] = 3
        let result = try HistogramAnalysis.analyze(dataset(values, step: 1440), request: HistogramRequest(
            primaryID: "primary", grouping: .month, primaryBins: .init(width: 1, start: 0)))
        XCTAssertEqual(result.groups.count, 12)
        XCTAssertEqual(result.groups[0].label, "Jan")
        XCTAssertEqual(result.groupTotals, [2] + Array(repeating: 0, count: 11))
        XCTAssertEqual(result.counts.map { $0[0] }.reduce(0, +), 2)
        XCTAssertTrue(result.counts.allSatisfy { $0.dropFirst().allSatisfy { $0 == 0 } })
    }

    func testHourGroupingUsesFileWallClockAndAllTwentyFourGroups() throws {
        var values = Array<Double?>(repeating: nil, count: 25)
        values[0] = 1
        values[1] = 2
        values[24] = 3
        let result = try HistogramAnalysis.analyze(dataset(values), request: HistogramRequest(primaryID: "primary", grouping: .hour))
        XCTAssertEqual(result.groups.count, 24)
        XCTAssertEqual(result.groupTotals[0], 2)
        XCTAssertEqual(result.groupTotals[1], 1)
        XCTAssertEqual(result.groupTotals.dropFirst(2).reduce(0, +), 0)
    }

    func testConditionalAndJointNormalizationHaveDifferentDenominators() throws {
        var values = Array<Double?>(repeating: nil, count: 25)
        values[0] = 1
        values[24] = 1
        values[1] = 1
        let request = HistogramRequest(primaryID: "primary", grouping: .hour, primaryBins: .init(width: 1, start: 0))
        let joint = try HistogramAnalysis.analyze(dataset(values), request: request)
        var conditionalRequest = request
        conditionalRequest.normalization = .withinGroup
        let conditional = try HistogramAnalysis.analyze(dataset(values), request: conditionalRequest)
        XCTAssertEqual(joint.percentages.flatMap { $0 }.reduce(0, +), 100, accuracy: 1e-9)
        XCTAssertEqual(conditional.percentages.map { $0[0] }.reduce(0, +), 100, accuracy: 1e-9)
        XCTAssertEqual(conditional.percentages.map { $0[1] }.reduce(0, +), 100, accuracy: 1e-9)
        XCTAssertEqual(conditional.counts, joint.counts)
    }

    func testTwoColumnCountsRequireValidConcurrentPairs() throws {
        let data = dataset([1, 2, 3, nil, 4], secondary: [10, nil, 20, 30])
        let result = try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary", grouping: .column,
            secondaryID: "secondary", primaryBins: .init(width: 1, start: 0), secondaryBins: .init(width: 10, start: 0)))
        XCTAssertEqual(result.primaryValues, [1, 3])
        XCTAssertEqual(result.sampleCount, 2)
        XCTAssertEqual(result.includedCount, 2)
        XCTAssertEqual(result.counts.flatMap { $0 }.reduce(0, +), 2)
        XCTAssertEqual(result.percentages.flatMap { $0 }.reduce(0, +), 100)
    }

    func testTwoColumnCustomStartRetainsTotalPairDenominator() throws {
        let result = try HistogramAnalysis.analyze(dataset([0, 1, 2], secondary: [0, 1, 2]), request: HistogramRequest(
            primaryID: "primary", grouping: .column, secondaryID: "secondary",
            primaryBins: .init(width: 1, start: 1), secondaryBins: .init(width: 1, start: 1)))
        XCTAssertEqual(result.sampleCount, 3)
        XCTAssertEqual(result.includedCount, 2)
        XCTAssertEqual(result.percentages.flatMap { $0 }.reduce(0, +), 200.0 / 3, accuracy: 1e-9)
    }

    func testDateRangeColumnAndIndexSelectionsIntersect() throws {
        let data = dataset([0, 1, 2, 3, 4, 5], secondary: [0, 1, 2, 3, 4, 5], start: "2020-01-30T00:00:00Z", step: 1440)
        let selection = HistogramSelection(year: 2020, month: 2, startDate: date("2020-02-02T00:00:00Z"),
            endDate: date("2020-02-04T00:00:00Z"), columnID: "secondary", minimum: 3, maximum: 4,
            includedIndices: [3, 4, 5])
        let result = try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary", selection: selection))
        XCTAssertEqual(result.primaryValues, [3, 4])
        XCTAssertEqual(result.sampleCount, 2)
    }

    func testGenericNegativeDataAndAllMissingSentinels() throws {
        let result = try HistogramAnalysis.analyze(dataset([-10, -1, 0, 1, 9999, -9999, -999999, .nan], kind: "temperature", unit: "C"),
            request: HistogramRequest(primaryID: "primary"))
        XCTAssertEqual(result.primaryValues, [-10, -1, 0, 1])
        XCTAssertLessThan(try XCTUnwrap(result.bins.first).lower, 0)
        XCTAssertEqual(result.includedCount, 4)
        let vertical = try HistogramAnalysis.analyze(dataset([-2, -1, 1], kind: "vertical_wind_speed"), request: HistogramRequest(primaryID: "primary"))
        XCTAssertEqual(vertical.primaryValues, [-2, -1, 1])
    }

    func testWindDirectionIncludesNorth360AndRejectsOutsideRange() throws {
        let result = try HistogramAnalysis.analyze(dataset([0, 360, -1, 361], kind: "wind_direction", unit: "deg"),
            request: HistogramRequest(primaryID: "primary", primaryBins: .init(width: 30, start: 0)))
        XCTAssertEqual(result.sampleCount, 2)
        XCTAssertEqual(result.includedCount, 2)
    }

    func testMonthComparisonReplacesSelectedMonthAndTracksBinnedMarginals() throws {
        let data = dataset([0, 1, 2], start: "2020-01-31T00:00:00Z", step: 1440)
        let result = try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary", grouping: .month,
            primaryBins: .init(width: 1, start: 1), selection: .init(month: 1)))
        XCTAssertEqual(result.sampleCount, 3)
        XCTAssertEqual(result.normalizationCount, 2)
        XCTAssertEqual(result.rawGroupTotals[0], 1)
        XCTAssertEqual(result.rawGroupTotals[1], 2)
        XCTAssertEqual(result.groupTotals[0], 0)
        XCTAssertEqual(result.groupTotals[1], 2)
        XCTAssertEqual(result.percentages.flatMap { $0 }.reduce(0, +), 100)
    }

    func testNativeTwoColumnAutoGridTargetsTwentyToFiftyBinsPerAxis() throws {
        let values = (0..<100).map { Double($0) / 10 }
        let data = dataset(values.map(Optional.some), secondary: values.reversed().map(Optional.some))
        let one = try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary"))
        let two = try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary", grouping: .column, secondaryID: "secondary"))
        XCTAssertTrue((40...80).contains(one.bins.count))
        XCTAssertTrue((20...50).contains(two.bins.count))
        XCTAssertTrue((20...50).contains(two.groups.count))
        XCTAssertEqual(two.includedCount, 100)
        XCTAssertEqual(two.normalizationCount, 100)
    }

    func testExcessivelyNarrowCustomWidthFallsBackToAutomaticGrid() throws {
        let data = dataset([0, 1, 2])
        let automatic = try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary"))
        let narrow = try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary", primaryBins: .init(width: 0.0000001)))
        XCTAssertEqual(narrow.bins.count, automatic.bins.count)
        XCTAssertEqual(narrow.bins.first?.width, automatic.bins.first?.width)
    }

    func testInvalidRequestsAndExcessiveCellCountsFail() throws {
        let data = dataset([1, 2])
        XCTAssertThrowsError(try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "missing")))
        XCTAssertThrowsError(try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary", grouping: .column)))
        XCTAssertThrowsError(try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary", primaryBins: .init(width: 0))))
        XCTAssertThrowsError(try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary", selection: .init(month: 13))))
        XCTAssertThrowsError(try HistogramAnalysis.analyze(data, request: HistogramRequest(primaryID: "primary", selection: .init(minimum: 2, maximum: 1))))
        XCTAssertThrowsError(try HistogramAnalysis.analyze(dataset([nil, -999999]), request: HistogramRequest(primaryID: "primary")))
    }
}
