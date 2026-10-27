import XCTest
@testable import WindLabMac

final class TimeSeriesRenderingTests: XCTestCase {
    func testPixelEnvelopeKeepsNarrowPeakTroughTailAndOriginalIdentity() {
        let points = (0..<10001).map { index in
            SeriesPoint(x: Double(index), y: index == 4321 ? 90 : index == 4322 ? -30 : 5)
        }
        let reduced = TimeSeriesRendering.reduce(points: points, range: 0...10000, pixelWidth: 100)
        XCTAssertLessThanOrEqual(reduced.count, 400)
        XCTAssertEqual(reduced.first?.id, points.first?.id)
        XCTAssertEqual(reduced.last?.id, points.last?.id)
        XCTAssertTrue(reduced.contains { $0.id == points[4321].id && $0.y == 90 })
        XCTAssertTrue(reduced.contains { $0.id == points[4322].id && $0.y == -30 })
        XCTAssertEqual(reduced.map(\.x), reduced.map(\.x).sorted())
        XCTAssertTrue(reduced.allSatisfy { point in points[Int(point.x)].id == point.id })
    }

    func testMissingRunsRemainExplicitAndConsecutiveBreaksCompress() {
        let points = (0..<1000).map { index in
            SeriesPoint(x: Double(index), y: (400...450).contains(index) ? .nan : Double(index % 13))
        }
        let reduced = TimeSeriesRendering.reduce(points: points, range: 0...999, pixelWidth: 10)
        let breaks = reduced.indices.filter { !reduced[$0].y.isFinite }
        XCTAssertEqual(breaks.count, 1)
        let gap = breaks[0]
        XCTAssertEqual(reduced[gap].id, points[400].id)
        XCTAssertEqual(reduced[gap - 1].id, points[399].id)
        XCTAssertEqual(reduced[gap + 1].id, points[451].id)
        XCTAssertEqual(reduced.last?.id, points.last?.id)
        XCTAssertLessThanOrEqual(reduced.count, 4 * 10 * 2 + 1)
    }

    func testViewportRetainsOneNeighbourOnEachSideAndNoDistantData() {
        let points = (0..<1000).map { SeriesPoint(x: Double($0), y: Double($0)) }
        let reduced = TimeSeriesRendering.reduce(points: points, range: 100...110, pixelWidth: 100)
        XCTAssertEqual(reduced.map(\.x), (99...111).map(Double.init))
        XCTAssertEqual(reduced.first?.id, points[99].id)
        XCTAssertEqual(reduced.last?.id, points[111].id)
        let between = TimeSeriesRendering.reduce(points: points, range: 100.2...100.8, pixelWidth: 50)
        XCTAssertEqual(between.map(\.x), [100, 101])
    }

    func testNarrowViewportAndZeroPixelWidthKeepTerminalExtrema() {
        let points = [SeriesPoint(x: 0, y: 5), SeriesPoint(x: 1, y: 10),
                      SeriesPoint(x: 2, y: -2), SeriesPoint(x: 3, y: 6)]
        XCTAssertEqual(TimeSeriesRendering.reduce(points: points, range: 0...3, pixelWidth: 0).map(\.y), [5, 10, -2, 6])
        XCTAssertEqual(TimeSeriesRendering.reduce(points: points, range: 2...2, pixelWidth: 1).map(\.x), [1, 2, 3])
        XCTAssertEqual(TimeSeriesRendering.reduce(points: points, range: 10...11, pixelWidth: 20).map(\.x), [3])
        XCTAssertEqual(TimeSeriesRendering.reduce(points: points, range: -10 ... -1, pixelWidth: 20).map(\.x), [0])
        XCTAssertTrue(TimeSeriesRendering.reduce(points: [], range: 0...1, pixelWidth: 20).isEmpty)
    }
}
