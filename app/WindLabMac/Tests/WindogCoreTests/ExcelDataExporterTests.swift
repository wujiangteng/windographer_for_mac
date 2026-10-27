import XCTest
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import WindogCore

final class ExcelDataExporterTests: XCTestCase {
    func testWorkbookZIPRelationshipsUnicodeAndNumericCells() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.xlsx")
        let dataset = WindExportDataSet(name: "Sample", startDate: Date(timeIntervalSince1970: 0), timeStepMinutes: 60, columns: [
            WindExportColumn(id: "a", label: "=1+1 测风 & <wind> \"A\"", unit: "m/s", values: [1.25, nil, .nan]),
            WindExportColumn(id: "b", label: "Other", unit: "", values: [2, .infinity])
        ])
        try ExcelDataExporter.write(dataset, to: url)
        let listing = try IndependentZIPReader.run(["-Z1", url.path])
        let entries = Set(String(decoding: listing, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
        let expected: Set<String> = ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"]
        XCTAssertEqual(entries, expected)
        // Validate every ZIP entry and its checksum before parsing independent XML.
        _ = try IndependentZIPReader.run(["-t", url.path])
        let extracted = directory.appendingPathComponent("unpacked")
        _ = try IndependentZIPReader.run(["-qq", url.path, "-d", extracted.path])
        var documents: [String: XMLDocument] = [:]
        for entry in entries {
            documents[entry] = try XMLDocument(data: Data(contentsOf: extracted.appendingPathComponent(entry)), options: .nodePreserveAll)
        }
        let sheet = try XCTUnwrap(documents["xl/worksheets/sheet1.xml"])
        XCTAssertEqual(sheet.rootElement()?.uri, "http://schemas.openxmlformats.org/spreadsheetml/2006/main")
        let cellNodes = try sheet.nodes(forXPath: "//*[local-name()='c']")
        var cells: [String: XMLElement] = [:]
        for node in cellNodes {
            let cell = try XCTUnwrap(node as? XMLElement)
            let address = try XCTUnwrap(cell.attribute(forName: "r")?.stringValue)
            XCTAssertNil(cells.updateValue(cell, forKey: address), "Duplicate cell address")
        }
        func value(_ address: String, path: String) throws -> String? {
            try cells[address]?.nodes(forXPath: path).first?.stringValue
        }
        XCTAssertEqual(cells["B1"]?.attribute(forName: "t")?.stringValue, "inlineStr")
        XCTAssertEqual(try value("B1", path: "./*[local-name()='is']/*[local-name()='t']"), "=1+1 测风 & <wind> \"A\" [m/s]")
        XCTAssertTrue(try sheet.nodes(forXPath: "//*[local-name()='f']").isEmpty)
        XCTAssertEqual(cells["B2"]?.attribute(forName: "t")?.stringValue, "n")
        XCTAssertEqual(try value("B2", path: "./*[local-name()='v']").flatMap(Double.init), 1.25)
        XCTAssertEqual(try value("A2", path: "./*[local-name()='is']/*[local-name()='t']"), "1970-01-01 00:00")
        XCTAssertEqual(try value("A3", path: "./*[local-name()='is']/*[local-name()='t']"), "1970-01-01 01:00")
        for address in ["B3", "B4", "C3", "C4"] { XCTAssertNil(cells[address]) }
        XCTAssertEqual(try sheet.nodes(forXPath: "//*[local-name()='row']").count, 4)
        let packageRelationships = try XCTUnwrap(documents["_rels/.rels"])
        let workbookRelationships = try XCTUnwrap(documents["xl/_rels/workbook.xml.rels"])
        XCTAssertEqual(try packageRelationships.nodes(forXPath: "//*[local-name()='Relationship']/@Target").map(\.stringValue), ["xl/workbook.xml"])
        XCTAssertEqual(try workbookRelationships.nodes(forXPath: "//*[local-name()='Relationship']/@Target").map(\.stringValue), ["worksheets/sheet1.xml"])
        // Atomic replacement should work, not append a second ZIP to the old file.
        let previous = try Data(contentsOf: url)
        try ExcelDataExporter.write(dataset, to: url)
        XCTAssertEqual(try Data(contentsOf: url), previous)
    }

    func testRejectsColumnLimitWithoutReplacingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.xlsx")
        try Data("existing".utf8).write(to: url)
        let columns = (0..<16_384).map { WindExportColumn(id: "\($0)", label: "C", unit: "", values: [1]) }
        let dataset = WindExportDataSet(name: "Too wide", startDate: Date(), timeStepMinutes: 1, columns: columns)
        XCTAssertThrowsError(try ExcelDataExporter.write(dataset, to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "existing")
    }

    func testInvalidXMLHeaderDoesNotReplaceExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.xlsx")
        try Data("existing".utf8).write(to: url)
        let dataset = WindExportDataSet(name: "Bad", startDate: Date(), timeStepMinutes: 1, columns: [
            WindExportColumn(id: "a", label: "bad\u{1}control", unit: "", values: [1])
        ])
        XCTAssertThrowsError(try ExcelDataExporter.write(dataset, to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "existing")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.xlsx"])
    }
}
