import Foundation
import WindogCore

/// Applies the same draft to previews and every downstream analysis, without mutating source samples.
enum ConfigurationEditing {
    static let types = ["Wind Speed": "wind_speed", "Wind Direction": "wind_direction",
        "Vert. Wind Speed": "vertical_wind_speed", "Temperature": "temperature", "Air Pressure": "pressure",
        "Relative Humidity": "humidity", "Wind Turbine Output": "turbine_output", "Turbulence Intensity": "turbulence_intensity", "Air Density": "density", "Wind Power Density": "power_density",
        "Quality": "quality", "Other": "other"]

    static func validate(_ draft: DataSetConfiguration) throws {
        guard !draft.columns.isEmpty, Set(draft.columns.map(\.id)).count == draft.columns.count else {
            throw WindogError.invalid("Keep at least one data column with a unique identifier.")
        }
        let info = draft.dataSet
        guard info.latitude.isFinite, abs(info.latitude) <= 90, info.longitude.isFinite, abs(info.longitude) <= 180,
              info.elevation.isFinite, info.invalidValue.isFinite, info.calmThreshold.isFinite, info.calmThreshold >= 0 else {
            throw WindogError.invalid("Enter valid coordinates, elevation, missing value and a nonnegative calm threshold.")
        }
        for column in draft.columns {
            guard !column.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  column.height == nil || column.height!.isFinite else {
                throw WindogError.invalid("Column labels must not be empty and heights must be finite.")
            }
            if let calculation = column.calculation {
                guard calculation.multiplier.isFinite, calculation.offset.isFinite else {
                    throw WindogError.invalid("Calculation coefficients must be finite.")
                }
            }
        }
    }

    static func apply(_ source: WindExportDataSet, _ draft: DataSetConfiguration, visibleOnly: Bool = false) throws -> WindExportDataSet {
        if draft.columns.isEmpty { return source }
        try validate(draft)
        let originals = Dictionary(uniqueKeysWithValues: source.columns.map { ($0.id, $0) })
        let edits = Dictionary(uniqueKeysWithValues: draft.columns.map { ($0.id, $0) })
        var cache: [String: [Double?]] = [:]
        var visiting = Set<String>()
        func values(_ id: String) throws -> [Double?] {
            if let result = cache[id] { return result }
            guard visiting.insert(id).inserted else { throw WindogError.invalid("Calculated columns contain a circular reference.") }
            defer { visiting.remove(id) }
            guard let edit = edits[id] else { throw WindogError.invalid("A calculated column references a deleted column.") }
            let result: [Double?]
            if let calculation = edit.calculation {
                if let stored = calculation.staticValues { result = stored }
                else if let sourceID = calculation.sourceID {
                    result = try values(sourceID).map { value in
                        guard let value else { return nil }
                        let converted = value * calculation.multiplier + calculation.offset
                        return converted.isFinite ? converted : nil
                    }
                } else { result = Array(repeating: calculation.offset, count: source.rowCount) }
            } else { result = originals[id]?.values ?? [] }
            let valid = result.map { value -> Double? in
                guard let value, value.isFinite, value != draft.dataSet.invalidValue else { return nil }
                return value
            }
            cache[id] = valid
            return valid
        }
        let columns: [WindExportColumn] = try draft.columns.filter { !visibleOnly || $0.visible }.map { edit -> WindExportColumn in
            let original = originals[edit.id]
            let speed: String?
            if edit.associated.speed == "<nearest in height>" {
                let candidates = draft.columns.filter { $0.type == "Wind Speed" && $0.subtype == "Mean" && $0.id != edit.id }
                let height = edit.height ?? 0
                speed = candidates.min { abs(($0.height ?? 0) - height) < abs(($1.height ?? 0) - height) }?.id
            } else if edit.associated.speed == "<none>" { speed = nil }
            else { speed = draft.columns.first { $0.id == edit.associated.speed || $0.label == edit.associated.speed }?.id }
            let kind: String? = edit.type == "Other" && ["density", "power_density"].contains(original?.kind ?? "") ? original?.kind : types[edit.type]
            let samples = try values(edit.id)
            return WindExportColumn(id: edit.id, label: edit.label, unit: edit.unit, values: samples,
                height: edit.height, kind: kind, subtype: edit.subtype, colorName: edit.colorName,
                associatedSpeedID: speed, flagIntervals: original?.flagIntervals)
        }
        let info = draft.dataSet
        let startDate = source.startDate.addingTimeInterval(info.timestampsIndicate == "End" ? -Double(source.timeStepMinutes) * 60 : 0)
        return WindExportDataSet(name: info.name.isEmpty ? source.name : info.name, startDate: startDate,
            timeStepMinutes: source.timeStepMinutes, columns: visibleOnly ? columns.filter { !$0.values.isEmpty } : columns,
            metadata: WindSummaryMetadata(latitude: source.metadata?.latitude != nil || info.latitude != 0 ? info.latitude : nil,
                longitude: source.metadata?.longitude != nil || info.longitude != 0 ? info.longitude : nil,
                elevation: source.metadata?.elevation != nil || info.elevation != 0 ? info.elevation : nil,
                calmThreshold: info.calmThreshold), flags: source.flags)
    }
}

/// A WindLab JSON template, deliberately distinct from unrecovered proprietary Windows templates.
struct ConfigurationTemplate: Codable {
    var format = "windlab-configuration-1"
    var columns: [Column]
    struct Column: Codable {
        var label: String
        var unit: String
        var type: String
        var subtype: String
        var color: String
        var height: Double?
        var visible: Bool
        var associations: [Int?]
    }
    init(_ draft: DataSetConfiguration) {
        func index(_ value: String) -> Int? { draft.columns.firstIndex { $0.id == value || $0.label == value } }
        columns = draft.columns.map { c in
            Column(label: c.label, unit: c.unit, type: c.type, subtype: c.subtype, color: c.colorName, height: c.height,
                visible: c.visible, associations: [index(c.associated.stdDev), index(c.associated.min), index(c.associated.max),
                    c.associated.speed == "<nearest in height>" ? -1 : index(c.associated.speed)])
        }
    }
    func applying(to draft: DataSetConfiguration) throws -> DataSetConfiguration {
        guard format == "windlab-configuration-1", columns.count == draft.columns.count else {
            throw WindogError.invalid("Use a WindLab template with the same number of columns. Columns map by position; samples are never imported from templates.")
        }
        var result = draft
        for i in columns.indices {
            let c = columns[i]
            guard c.associations.count == 4 else { throw WindogError.invalid("Invalid template associations.") }
            func reference(_ index: Int?) throws -> String {
                guard let index else { return "<none>" }
                if index == -1 { return "<nearest in height>" }
                guard result.columns.indices.contains(index) else { throw WindogError.invalid("Invalid template column reference.") }
                return result.columns[index].id
            }
            result.columns[i].label = c.label; result.columns[i].unit = c.unit; result.columns[i].type = c.type
            result.columns[i].subtype = c.subtype; result.columns[i].colorName = c.color; result.columns[i].height = c.height
            result.columns[i].visible = c.visible
            result.columns[i].associated = try AssociatedColumns(stdDev: reference(c.associations[0]), min: reference(c.associations[1]),
                max: reference(c.associations[2]), speed: reference(c.associations[3]))
            result.columns[i].preview = .empty
        }
        try ConfigurationEditing.validate(result)
        return result
    }
}
