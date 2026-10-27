import Foundation
import WindogCore

enum NativeFlagFiltering {
    static func applying(to dataset: WindExportDataSet, enabled: Bool, includeUnflagged: Bool,
                         flagIDs: Set<UInt16>, targetIDs: Set<String>? = nil) -> WindExportDataSet {
        guard enabled else { return dataset }
        let columns = dataset.columns.map { column -> WindExportColumn in
            if let targetIDs, !targetIDs.contains(column.id) { return column }
            guard let intervals = column.flagIntervals else { return column }
            if includeUnflagged && intervals.allSatisfy({ flagIDs.contains($0.flagID) }) { return column }
            let indices = WindogFlagSelection.includedIndices(intervals: intervals, rowCount: column.values.count,
                                                             includeUnflagged: includeUnflagged, flagIDs: flagIDs)
            return WindExportColumn(id: column.id, label: column.label, unit: column.unit,
                                    values: column.values.enumerated().map { indices.contains($0.offset) ? $0.element : nil },
                                    height: column.height, kind: column.kind, subtype: column.subtype,
                                    colorName: column.colorName, associatedSpeedID: column.associatedSpeedID,
                                    flagIntervals: intervals)
        }
        return WindExportDataSet(name: dataset.name, startDate: dataset.startDate, timeStepMinutes: dataset.timeStepMinutes,
                                 columns: columns, metadata: dataset.metadata, flags: dataset.flags)
    }
}
