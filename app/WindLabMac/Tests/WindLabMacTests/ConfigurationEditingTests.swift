import XCTest
import WindogCore
@testable import WindLabMac

final class ConfigurationEditingTests: XCTestCase {
    private var source: WindExportDataSet {
        WindExportDataSet(name: "source", startDate: Date(timeIntervalSince1970: 0), timeStepMinutes: 60,
            columns: [WindExportColumn(id: "a", label: "Speed 10m", unit: "m/s", values: [1,nil,3,9999], height: 10, kind: "wind_speed", subtype: "Mean"),
                WindExportColumn(id: "b", label: "Direction", unit: "deg", values: [0,90,180,270], height: 10, kind: "wind_direction", subtype: "Mean")])
    }
    private var draft: DataSetConfiguration {
        DataSetConfiguration(decoded: NativeConfigurationAnalysis.configuration(dataset: source))
    }
    func testDraftAppliesDeletionDerivedSamplesAndSourceRemainsUnchanged() throws {
        var config = draft
        config.columns.removeLast()
        var derived = config.columns[0]
        derived.id = "calculated"; derived.label = "Converted"
        derived.calculation = ColumnCalculation(sourceID: "a", multiplier: 2, offset: 1)
        config.columns.append(derived)
        let result = try ConfigurationEditing.apply(source, config)
        XCTAssertEqual(result.columns.map(\.id), ["a", "calculated"])
        XCTAssertEqual(result.columns[1].values, [3,nil,7,nil])
        XCTAssertEqual(source.columns[0].values.last!, 9999)
        config.columns[0].calculation = ColumnCalculation(sourceID: "calculated")
        XCTAssertThrowsError(try ConfigurationEditing.apply(source, config))
    }
    func testTemplateMapsAssociationsByPositionAcrossDifferentIDs() throws {
        var config = draft
        config.columns[1].associated.speed = "a"
        config.columns[0].label = "duplicate"
        config.columns[1].label = "duplicate"
        let bytes = try JSONEncoder().encode(ConfigurationTemplate(config))
        let template = try JSONDecoder().decode(ConfigurationTemplate.self, from: bytes)
        var destination = draft
        destination.columns[0].id = "new-a"; destination.columns[1].id = "new-b"
        let result = try template.applying(to: destination)
        XCTAssertEqual(result.columns[1].associated.speed, "new-a")
        XCTAssertEqual(result.columns[0].id, "new-a")
        destination.columns.removeLast()
        XCTAssertThrowsError(try template.applying(to: destination))
    }
    func testMissingSentinelEndTimestampAndStaticCopyAffectAnalysisOnly() throws {
        var config = draft
        config.dataSet.invalidValue = 3
        config.dataSet.timestampsIndicate = "End"
        config.columns[1].calculation = ColumnCalculation(sourceID: nil, staticValues: [2,4,nil,8])
        let result = try ConfigurationEditing.apply(source, config)
        XCTAssertNil(result.columns[0].values[2])
        XCTAssertEqual(result.columns[1].values, [2,4,nil,8])
        XCTAssertEqual(result.startDate, source.startDate.addingTimeInterval(-3600))
        XCTAssertEqual(source.startDate, Date(timeIntervalSince1970: 0))
    }
    func testConfiguredSpeedAssociationChangesRoseCalmSelection() throws {
        var config = draft
        config.columns[1].associated.speed = "a"
        let result = try ConfigurationEditing.apply(source, config)
        XCTAssertEqual(result.columns[1].associatedSpeedID, "a")
        config.columns[1].associated.speed = "<none>"
        XCTAssertNil(try ConfigurationEditing.apply(source, config).columns[1].associatedSpeedID)
    }
}
