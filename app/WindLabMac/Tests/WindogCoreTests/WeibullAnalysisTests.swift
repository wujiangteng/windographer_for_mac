import XCTest
@testable import WindogCore

final class WeibullAnalysisTests: XCTestCase {
    private func sampleValues() throws -> [Double] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("test-data/source.windog")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local sample unavailable") }
        let document = try WindogDocument(contentsOf: url)
        return document.values(for: document.columns[0]).map(Double.init)
    }

    func testRealSampleAgainstIndependentNativeReconstruction() throws {
        let analysis = try WeibullAnalysis.analyze(sampleValues())
        XCTAssertEqual(analysis.sampleCount, 8753)
        XCTAssertEqual(analysis.mean, 9.766409229628055, accuracy: 1e-10)
        XCTAssertEqual(analysis.powerDensity, 987.8963392194269, accuracy: 1e-8)
        XCTAssertEqual(analysis.bins.count, 50)
        XCTAssertEqual(analysis.bins.map(\.count).reduce(0, +), 8753)
        let expected: [(WeibullMethod, Double, Double, Double)] = [
            (.maximumLikelihood, 2.1582114696502686, 11.005415916442871, 0.92267217943),
            (.leastSquares, 1.9985847202563867, 11.098103468958724, 0.92464101210),
            (.wasp, 2.3764807953669864, 11.222593153875021, 0.90404729031)
        ]
        for (method, shape, scale, rSquared) in expected {
            let item = try XCTUnwrap(analysis.fits.first { $0.method == method })
            let fit = try XCTUnwrap(item.parameters)
            XCTAssertEqual(fit.shape, shape, accuracy: 1e-5, method.rawValue)
            XCTAssertEqual(fit.scale, scale, accuracy: 1e-5, method.rawValue)
            XCTAssertEqual(try XCTUnwrap(item.rSquared), rSquared, accuracy: 1e-6, method.rawValue)
        }
    }

    func testLeastSquaresKeepsNegativeLogCoordinates() throws {
        let count = 1000
        let values = (0..<count).map { index in
            10 * sqrt(-log1p(-(Double(index) + 0.5) / Double(count)))
        }
        let fit = try XCTUnwrap(WeibullAnalysis.leastSquares(values))
        XCTAssertEqual(fit.shape, 2, accuracy: 1e-10)
        XCTAssertEqual(fit.scale, 10, accuracy: 1e-10)
        let result = try WeibullAnalysis.analyze(values)
        let wasp = try XCTUnwrap(result.fits.first { $0.method == .wasp }?.parameters)
        XCTAssertEqual(wasp.thirdMoment, result.meanCube, accuracy: 1e-7)
        XCTAssertEqual(wasp.survival(result.mean), result.proportionAboveMean, accuracy: 1e-9)
    }

    func testDisplayBinsDoNotChangeFittingOrGoodnessOfFit() throws {
        let values = try sampleValues()
        let standard = try WeibullAnalysis.analyze(values)
        let changed = try WeibullAnalysis.analyze(values, binWidth: 1, binStart: 1, halfFirstBin: true)
        XCTAssertEqual(changed.bins.first?.width, 0.5)
        XCTAssertEqual(changed.bins.dropFirst().first?.width, 1)
        for (first, second) in zip(standard.fits, changed.fits) {
            XCTAssertEqual(first.parameters?.shape, second.parameters?.shape)
            XCTAssertEqual(first.parameters?.scale, second.parameters?.scale)
            XCTAssertEqual(first.rSquared, second.rSquared)
        }
        XCTAssertEqual(changed.sampleCount, standard.sampleCount)
    }

    func testZeroDegenerateAndInvalidSamples() throws {
        let empty = [Double.nan, .infinity, -9999, 9999]
        XCTAssertThrowsError(try WeibullAnalysis.analyze(empty))
        XCTAssertThrowsError(try WeibullAnalysis.analyze([1, 2], binWidth: 0))
        let zeros = try WeibullAnalysis.analyze(Array(repeating: 0, count: 20))
        XCTAssertEqual(zeros.mean, 0)
        XCTAssertEqual(zeros.powerDensity, 0)
        XCTAssertTrue(zeros.fits.allSatisfy { $0.parameters == nil })
        let mixed = [0.0, 0, 0.5, 1, 1, 2, 3, 4, 6, 8, 10, 12]
        let first = try WeibullAnalysis.analyze(mixed)
        let second = try WeibullAnalysis.analyze(mixed)
        XCTAssertEqual(first.fits[0].parameters?.shape, second.fits[0].parameters?.shape)
        XCTAssertEqual(first.fits[0].parameters?.scale, second.fits[0].parameters?.scale)
    }

    func testHalfFirstBinAndFinalEdgeCount() throws {
        let result = try WeibullAnalysis.analyze([0, 0.25, 0.5, 1, 1.5, 2], binWidth: 0.5, binStart: 0, halfFirstBin: true)
        XCTAssertEqual(result.bins.first?.lower, 0)
        XCTAssertEqual(result.bins.first?.upper, 0.25)
        XCTAssertEqual(result.bins.map(\.count).reduce(0, +), 6)
        XCTAssertEqual(result.bins[1].count, 2)
        XCTAssertEqual(result.bins.map(\.percentage).reduce(0, +), 100, accuracy: 1e-10)
    }

    func testNativeDateAndColumnFiltering() throws {
        let start = Date(timeIntervalSince1970: 1_656_633_600)
        let dataset = WindExportDataSet(name: "filter", startDate: start, timeStepMinutes: 60, columns: [
            .init(id: "speed", label: "Wind", unit: "m/s", values: [1, 2, 3, 4, nil, -9999]),
            .init(id: "quality", label: "Quality", unit: "%", values: [99, 30, 95, 100, 100, 100])
        ])
        let filter = WindSampleSelection(year: 2022, month: 7, startDate: start.addingTimeInterval(3600),
                                         endDate: start.addingTimeInterval(3 * 3600), columnID: "quality", minimum: 90, maximum: 100)
        XCTAssertEqual(try filter.values(in: dataset, speedID: "speed"), [3])
        XCTAssertThrowsError(try filter.values(in: dataset, speedID: "missing"))
        XCTAssertThrowsError(try WindSampleSelection(minimum: 10, maximum: 2).values(in: dataset, speedID: "speed"))
    }
}
