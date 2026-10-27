import XCTest
@testable import WindogCore

final class WindogCoreTests: XCTestCase {
    private var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private func sample() throws -> WindogDocument {
        let url = root.appendingPathComponent("test-data/source.windog")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local sample unavailable") }
        return try WindogDocument(contentsOf: url)
    }

    func testContainerRejectsDamageAndWrongLengths() throws {
        let payload = Data("bounded zlib payload".utf8)
        let valid = try WindogContainer.encode(payload)
        XCTAssertEqual(try WindogContainer.decode(valid), payload)
        for count in [0, 3, 11] { XCTAssertThrowsError(try WindogContainer.decode(Data(valid.prefix(count)))) }
        var corrupt = valid
        corrupt[corrupt.count - 2] ^= 1
        XCTAssertThrowsError(try WindogContainer.decode(corrupt))
        var wrongSize = valid
        wrongSize[4] ^= 1
        XCTAssertThrowsError(try WindogContainer.decode(wrongSize))
        var variant = valid
        variant[3] = 3
        XCTAssertThrowsError(try WindogContainer.decode(variant))
        let extra = Data(valid.dropFirst(12)) + Data([0])
        var trailing = Data(valid.prefix(8))
        trailing.appendUInt32(WindogContainer.checksum(extra))
        trailing.append(extra)
        XCTAssertThrowsError(try WindogContainer.decode(trailing))
    }

    func testRealSampleAndZeroLengthColumns() throws {
        let document = try sample()
        XCTAssertEqual(document.writerVersion, "4.0.17")
        XCTAssertEqual(document.timeStepMinutes, 60)
        XCTAssertEqual(document.columns.count, 7)
        XCTAssertEqual(document.columns.filter { $0.count == 0 }.count, 3)
        XCTAssertEqual(document.flags.map(\.id), [100, 102, 104, 103, 101])
        XCTAssertEqual(document.values(for: document.columns[0])[0], 10.756, accuracy: 0.00001)
        XCTAssertEqual(document.columns[2].unit, "°")
        XCTAssertEqual(document.startDate.timeIntervalSince1970, 1_656_633_600)
        XCTAssertEqual(try document.encoded(), try Data(contentsOf: root.appendingPathComponent("test-data/source.windog")))
    }

    func testVariableLengthEditsPreserveUnknownBytesAndValues() throws {
        let document = try sample()
        let name = "150m 风速 renamed with a longer label"
        let changed = try document.applying([.init(index: 0, name: name, unit: "knots")])
        let reopened = try WindogDocument(container: changed.encoded())
        XCTAssertEqual(reopened.columns[0].name, name)
        XCTAssertEqual(reopened.columns[0].unit, "knots")
        for (before, after) in zip(document.columns, reopened.columns) {
            XCTAssertEqual(document.payload.subdata(in: before.dataRange), reopened.payload.subdata(in: after.dataRange))
        }
        let restored = try reopened.applying([.init(index: 0, name: document.columns[0].name, unit: document.columns[0].unit)])
        XCTAssertEqual(restored.payload, document.payload)
        let shortened = try document.applying([.init(index: 0, name: "A", unit: "m/s")])
        XCTAssertEqual(try WindogDocument(container: shortened.encoded()).columns[0].name, "A")
        XCTAssertThrowsError(try document.applying([.init(index: 0, name: "", unit: "m/s")]))
    }

    func testDistinctLocalCorpus() throws {
        let inventory = root.appendingPathComponent("analysis/windographer-4.0.20/sample_inventory.json")
        guard FileManager.default.fileExists(atPath: inventory.path) else { throw XCTSkip("Local corpus unavailable") }
        struct Entry: Decodable { let path: String; let sha256: String }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: inventory))
        var seen: Set<String> = []
        var documents = 0
        var columns = 0
        for entry in entries where seen.insert(entry.sha256).inserted {
            let document = try WindogDocument(contentsOf: root.appendingPathComponent(entry.path))
            let decodedAgain = try WindogContainer.decode(WindogContainer.encode(document.payload))
            XCTAssertEqual(decodedAgain, document.payload)
            documents += 1
            columns += document.columns.count
        }
        XCTAssertEqual(documents, 31)
        XCTAssertEqual(columns, 1905)
    }
}
