import XCTest
@testable import WindogCore

final class DataExportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_656_633_600)

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    func testDelimitedFilesWithIndependentCSVReader() throws {
        let dataset = WindExportDataSet(name: "测风", startDate: date, timeStepMinutes: 10, columns: [
            .init(id: "one", label: "风速,\"A\"\nsecond line", unit: "m/s", values: [10.756, nil, .infinity]),
            .init(id: "two", label: "Direction", unit: "°", values: [0, 360])
        ])
        try withDirectory { directory in
            for format in [WindExportFormat.csv, .tsv] {
                let file = directory.appendingPathComponent("table." + format.fileExtension)
                try DelimitedDataExporter.write(dataset, format: format, to: file)
                let rows = try IndependentDelimitedReader.read(file, delimiter: format == .csv ? "," : "\t")
                XCTAssertEqual(rows.count, 4)
                XCTAssertEqual(rows.map(\.count), [3, 3, 3, 3])
                XCTAssertEqual(rows[0][1], "风速,\"A\"\nsecond line [m/s]")
                XCTAssertEqual(rows[1][0], "2022-07-01 00:00")
                XCTAssertEqual(rows[3][0], "2022-07-01 00:20")
                XCTAssertEqual(Double(rows[1][1]), 10.756)
                XCTAssertEqual(rows[2][1], "-9999")
                XCTAssertEqual(rows[3][1], "-9999")
                XCTAssertEqual(rows[3][2], "-9999")
            }
        }
    }

    func testTimeRangePreservesSourceAlignment() throws {
        let dataset = WindExportDataSet(name: "example", startDate: date, timeStepMinutes: 10, columns: [
            .init(id: "s", label: "Speed", unit: "m/s", values: [1, 2, 3, 4]),
            .init(id: "d", label: "Direction", unit: "deg", values: [10, 20])
        ])
        let selected = try dataset.selecting(ids: ["s", "d"], start: date.addingTimeInterval(601), end: date.addingTimeInterval(1800))
        XCTAssertEqual(selected.startDate, date.addingTimeInterval(1200))
        XCTAssertEqual(selected.columns[0].values, [3, 4])
        XCTAssertTrue(selected.columns[1].values.isEmpty)
        XCTAssertThrowsError(try dataset.selecting(ids: ["unknown"]))
        XCTAssertThrowsError(try dataset.selecting(ids: ["s"], start: date.addingTimeInterval(10000)))
    }

    func testWAsPFrequenciesEdgesAndMissingPairs() throws {
        let dataset = WindExportDataSet(name: "Test", startDate: date, timeStepMinutes: 10, columns: [
            .init(id: "s", label: "Speed", unit: "m/s", values: [0, 1, 2, 1, 2, 9999, 3, -1, nil, 1]),
            .init(id: "d", label: "Direction", unit: "deg", values: [0, 0, 90, 360, 180, 0, 270, 0, 0, 361])
        ])
        try withDirectory { directory in
            let file = directory.appendingPathComponent("wind.tab")
            let options = WAsPExportOptions(speedID: "s", directionID: "d", sectors: 4,
                                            site: .init(latitude: 25, longitude: 120, height: 100))
            try WAsPDataExporter.write(dataset, options: options, to: file)
            let rows = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\r\n").filter { !$0.isEmpty }
            XCTAssertEqual(rows.count, 7)
            XCTAssertEqual(rows[2].split(whereSeparator: \.isWhitespace), ["4", "1.00", "0.00"])
            let percentages = rows[3].split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            XCTAssertEqual(percentages[0], 50)
            XCTAssertEqual(percentages.reduce(0, +), 100, accuracy: 0.000001)
            let bins = rows[4...].map { $0.split(whereSeparator: \.isWhitespace).compactMap { Double($0) } }
            XCTAssertEqual(bins.map { $0[0] }, [1, 2, 3])
            XCTAssertEqual(bins[0][1], 1000.0 / 3, accuracy: 0.000001)
            XCTAssertEqual(bins[1][1], 2000.0 / 3, accuracy: 0.000001)
            XCTAssertEqual(bins[2][4], 1000)
            for sector in 1...4 { XCTAssertEqual(bins.map { $0[sector] }.reduce(0, +), 1000, accuracy: 0.000001) }
            let halfWidth = WAsPExportOptions(speedID: "s", directionID: "d", sectors: 4, binWidth: 0.5,
                                             site: options.site)
            try WAsPDataExporter.write(dataset, options: halfWidth, to: file)
            let halfRows = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\r\n")
            XCTAssertEqual(halfRows[2], "\t\t4\t1.00\t0.00")
            XCTAssertTrue(halfRows[4].hasPrefix("0.500\t"))
        }
    }

    func testWAsPValidationPreservesDestination() throws {
        let dataset = WindExportDataSet(name: "Test", startDate: date, timeStepMinutes: 10, columns: [
            .init(id: "s", label: "Speed", unit: "knots", values: [2]),
            .init(id: "d", label: "Direction", unit: "deg", values: [0])
        ])
        try withDirectory { directory in
            let file = directory.appendingPathComponent("existing.tab")
            let original = Data("preserved".utf8)
            try original.write(to: file)
            XCTAssertThrowsError(try WAsPDataExporter.write(dataset, options: .init(
                speedID: "s", directionID: "d", site: .init(latitude: 0, longitude: 0, height: 100)), to: file))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }
}
