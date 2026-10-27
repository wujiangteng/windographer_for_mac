import XCTest
@testable import WindogCore

final class WindogFlagIntervalsTests: XCTestCase {
    private var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    func testSourceSynthesizedFlagIncludesBothEndpoints() throws {
        let document = try WindogDocument(contentsOf: root.appendingPathComponent("test-data/source.windog"))
        XCTAssertTrue(try document.flagIntervals(for: document.columns[0]).isEmpty)
        let column = try XCTUnwrap(document.columns.first { $0.name == "Speed 100 m Synthesized" })
        let intervals = try document.flagIntervals(for: column)
        XCTAssertEqual(intervals, [.init(flagID: 103, startIndex: 0, endIndex: 8759)])
        XCTAssertTrue(intervals[0].contains(0))
        XCTAssertTrue(intervals[0].contains(8759))
        XCTAssertFalse(intervals[0].contains(8760))
        let derived = try XCTUnwrap(document.columns.first { $0.name == "Speed 100 m Synthesized WPD" })
        XCTAssertEqual(try document.flagIntervals(for: derived), intervals)
    }

    func testCurrentScreenshotArchiveIntervalsAreColumnSpecific() throws {
        let url = URL(fileURLWithPath: "/Users/wudong/Documents/Data/Mast/测风数据/测风塔-海上新增/8468_0273-20201201-20221130-风向矫正-异塔插补2-0.174拟合.windog")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Screenshot archive unavailable") }
        let document = try WindogDocument(contentsOf: url)
        let mean = try XCTUnwrap(document.columns.first { $0.name == "Anemometer @100.0m A;wind_speed;Avg" })
        let maximum = try XCTUnwrap(document.columns.first { $0.name == "Anemometer @100.0m A;wind_speed;Max" })
        let intervals = try document.flagIntervals(for: mean)
        XCTAssertEqual(intervals.count, 17)
        XCTAssertEqual(intervals.first, .init(flagID: 103, startIndex: 1296, endIndex: 1727))
        XCTAssertTrue(try document.flagIntervals(for: maximum).isEmpty)
        for column in document.columns { _ = try document.flagIntervals(for: column) }
    }

    func testFlagMapRejectsUnknownSchemaIDAndInvalidIntervals() throws {
        let document = try WindogDocument(contentsOf: root.appendingPathComponent("test-data/source.windog"))
        let column = try XCTUnwrap(document.columns.first { $0.name == "Speed 100 m Synthesized" })
        let offset = column.dataRange.upperBound
        for (relative, byte) in [(0, UInt8(1)), (8, UInt8(255)), (16, UInt8(255)), (25, UInt8(255))] {
            var payload = document.payload
            payload[offset + relative] = byte
            let altered = try WindogDocument(payload: payload)
            let changed = altered.columns[column.index]
            XCTAssertThrowsError(try altered.flagIntervals(for: changed))
        }
    }

    func testSelectedFlagsUnionWithUnflaggedRows() {
        let intervals: [WindogFlagInterval] = [
            .init(flagID: 100, startIndex: 1, endIndex: 3),
            .init(flagID: 103, startIndex: 3, endIndex: 5)
        ]
        XCTAssertEqual(WindogFlagSelection.includedIndices(intervals: intervals, rowCount: 7,
                                                         includeUnflagged: true, flagIDs: [103]), [0, 3, 4, 5, 6])
        XCTAssertEqual(WindogFlagSelection.includedIndices(intervals: intervals, rowCount: 7,
                                                         includeUnflagged: false, flagIDs: [100]), [1, 2, 3])
        XCTAssertTrue(WindogFlagSelection.includedIndices(intervals: intervals, rowCount: 7,
                                                        includeUnflagged: false, flagIDs: []).isEmpty)
        XCTAssertEqual(WindogFlagSelection.includedIndices(intervals: [], rowCount: 3,
                                                         includeUnflagged: true, flagIDs: []), [0, 1, 2])
    }

    func testExistingCorpusFlagMapsDecodeWithoutScanning() throws {
        let inventory = root.appendingPathComponent("analysis/windographer-4.0.20/sample_inventory.json")
        struct Entry: Decodable { let path: String; let sha256: String }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: inventory))
        var seen: Set<String> = []
        var checked = 0
        for entry in entries where seen.insert(entry.sha256).inserted {
            let document = try WindogDocument(contentsOf: root.appendingPathComponent(entry.path))
            for column in document.columns {
                _ = try document.flagIntervals(for: column)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 1905)
    }
}
