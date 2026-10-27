import XCTest
@testable import WindogCore

final class TextDataImporterTests: XCTestCase {
    func testQuotedCSVAndMissingTimestampPreserveAlignment() throws {
        let text = """
        Latitude = 34.25
        Date/Time,"Speed, 100m [m/s]",Temperature [C],Unknown [Hz]
        2020-01-01 00:00,4,-2,3
        2020-01-01 00:10,5,-1,4
        2020-01-01 00:30,-9999,,6
        """
        let result = try TextDataImporter.parse(data: Data(text.utf8), name: "sample")
        XCTAssertEqual(result.timeStepMinutes, 10)
        XCTAssertEqual(result.rowCount, 4)
        XCTAssertEqual(result.columns[0].values, [4, 5, nil, nil])
        XCTAssertEqual(result.columns[0].label, "Speed, 100m")
        XCTAssertEqual(result.columns[0].height, 100)
        XCTAssertEqual(result.columns[1].values, [-2, -1, nil, nil])
        XCTAssertEqual(result.columns[2].unit, "Hz")
        XCTAssertEqual(result.metadata?.latitude, 34.25)
    }

    func testSemicolonsInTabAndCSVSensorLabelsDoNotChangeDelimiter() throws {
        for (delimiter, heading) in [("\t", "Anemometer @100m;wind_speed;Avg [m/s]"), (",", "\"Anemometer @100m;wind_speed;Avg, A [m/s]\"")] {
            let text = "Date/Time" + delimiter + heading + "\n2020-01-01 00:00" + delimiter + "4\n2020-01-01 00:10" + delimiter + "5"
            let result = try TextDataImporter.parse(data: Data(text.utf8), name: "sensor")
            XCTAssertEqual(result.columns.count, 1)
            XCTAssertEqual(result.columns[0].values, [4, 5])
            XCTAssertEqual(result.columns[0].height, 100)
        }
    }

    func testNRGMetadataAndUTF16() throws {
        let text = """
        Channel #\t1
        Description\tWind direction
        Height\t80 m
        Units\tdeg
        Date/Time\tCH1Avg\tCH1SD
        2022/12/01 00:00\t359\t2
        2022/12/01 00:10\t1\t3
        """
        var data = Data([0xff, 0xfe]); data.append(text.data(using: .utf16LittleEndian)!)
        let result = try TextDataImporter.parse(data: data, name: "NRG")
        XCTAssertEqual(result.columns[0].height, 80)
        XCTAssertEqual(result.columns[0].kind, "wind_direction")
        XCTAssertEqual(result.columns[0].subtype, "Mean")
        XCTAssertEqual(result.columns[1].subtype, "Std. dev.")
        XCTAssertEqual(result.columns[1].values, [2, 3])
    }

    func testRejectsDuplicateAndNonGridTimestamps() {
        for times in [["00:00", "00:10", "00:10"], ["00:00", "00:10", "00:25"]] {
            let text = "Date/Time\tSpeed [m/s]\n" + times.map { "2020-01-01 \($0)\t4" }.joined(separator: "\n")
            XCTAssertThrowsError(try TextDataImporter.parse(data: Data(text.utf8), name: "invalid"))
        }
    }

    func testCompactDatesDuplicateNamesAndBlankColumns() throws {
        let text = "Date/Time;Value;Value;Empty\n202001010000;1;2;\n202001010010;3;4;"
        let result = try TextDataImporter.parse(data: Data(text.utf8), name: "duplicates")
        XCTAssertEqual(result.columns.map(\.id), ["Value", "Value (2)", "Empty"])
        XCTAssertEqual(result.columns[2].values, [nil, nil])
        XCTAssertEqual(result.timeStepMinutes, 10)
    }
    func testCoordinatesAreNotWindDirectionsAndLegacyDegreeSymbolsAreDecoded() throws {
        let text = "Date/Time\tN [Deg]\tE [Deg]\tWD_100m_Avg [°]\tWD_100m_Std [°]\tWD_50m_B_Avg [°]\tTa_100m_Avg [°C]\n2020-01-01 00:00\t26.542\t120.32\t15\t2\t20\t17\n2020-01-01 00:10\t26.542\t120.32\t200\t3\t210\t18"
        let data = try XCTUnwrap(text.data(using: .windowsCP1252))
        let dataset = try TextDataImporter.parse(data: data, name: "legacy-export")
        XCTAssertEqual(dataset.columns.prefix(2).map(\.kind), ["other", "other"])
        XCTAssertEqual(dataset.columns[2].unit, "deg")
        XCTAssertEqual(dataset.columns[2].kind, "wind_direction")
        XCTAssertEqual(dataset.columns[3].subtype, "Std. dev.")
        XCTAssertEqual(dataset.columns[5].unit, "C")
        XCTAssertEqual(dataset.columns[5].kind, "temperature")
        let summary = try SummaryStatistics.analyze(dataset)
        XCTAssertEqual(Set(summary.roses.map(\.label)), ["WD_100m_Avg", "WD_50m_B_Avg"])
        XCTAssertTrue(summary.roses.allSatisfy { $0.points.filter { $0.fraction > 0 }.count == 2 })
        XCTAssertTrue(summary.roses.allSatisfy { $0.points.map(\.fraction).max()! < 1 })
    }

    func testLegacyMetadataAliasesRemainAvailableAfterParserRemoval() throws {
        let text = "Date/Time\t可靠性\tReliability\tVert. Wind Speed [m/s]\t风速极大值 [m/s]\t风速极小值 [m/s]\t风速偏差 [m/s]\tWind speed standard deviation [m/s]\n2020-01-01 00:00\t99\t98\t-2\t10\t1\t0.5\t0.6\n2020-01-01 00:10\t100\t99\t-1\t11\t2\t0.6\t0.7"
        let result = try TextDataImporter.parse(data: Data(text.utf8), name: "aliases")
        XCTAssertEqual(result.columns.prefix(2).map(\.kind), ["quality", "quality"])
        XCTAssertEqual(result.columns.prefix(2).map(\.unit), ["%", "%"])
        XCTAssertEqual(result.columns[2].kind, "vertical_wind_speed")
        XCTAssertEqual(result.columns[2].values, [-2,-1])
        XCTAssertEqual(result.columns.suffix(4).map(\.subtype), ["Max", "Min", "Std. dev.", "Std. dev."])
        XCTAssertEqual(WindColumnMetadata.kind(label: "压力", unit: ""), "pressure")
    }
}
