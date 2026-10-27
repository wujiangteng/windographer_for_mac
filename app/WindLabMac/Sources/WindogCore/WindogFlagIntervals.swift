import Foundation

/// An inclusive native row-index interval attached to one column and flag.
/// Serialization evidence: 544520 -> 626950 -> 658ba0 -> 6573d0.
public struct WindogFlagInterval: Decodable, Sendable, Equatable {
    public let flagID: UInt16
    public let startIndex: Int
    public let endIndex: Int

    public init(flagID: UInt16, startIndex: Int, endIndex: Int) {
        self.flagID = flagID
        self.startIndex = startIndex
        self.endIndex = endIndex
    }

    public func contains(_ rowIndex: Int) -> Bool {
        startIndex <= rowIndex && rowIndex <= endIndex
    }
}

extension WindogDocument {
    /// Reads the schema-0 flag map immediately following a schema-7 column's
    /// stored Float array. Unknown schemas fail explicitly; no byte-pattern scan
    /// is used and no missing/negative value is assumed to carry a quality flag.
    public func flagIntervals(for column: WindogColumn) throws -> [WindogFlagInterval] {
        guard columns.indices.contains(column.index),
              columns[column.index].channelID == column.channelID,
              columns[column.index].dataRange == column.dataRange else {
            throw WindogError.invalid("flag intervals require a column from this document")
        }
        var offset = column.dataRange.upperBound
        // Bound reads before the next column's known data array. The intervening
        // next header is not consumed by any accepted schema/count combination.
        let limit = columns.dropFirst(column.index + 1).first?.dataRange.lowerBound ?? payload.count
        func integer(_ width: Int) throws -> UInt32 {
            guard offset >= 0, width > 0, offset <= limit - width, offset <= payload.count - width else {
                throw WindogError.invalid("truncated column flag interval map")
            }
            var value: UInt32 = 0
            for byte in 0..<width { value |= UInt32(payload[offset + byte]) << UInt32(byte * 8) }
            offset += width
            return value
        }
        guard try integer(4) == 0 else { throw WindogError.unsupported("column flag map schema") }
        let groupCount = Int(try integer(4))
        let knownFlags = Set(flags.map(\.id))
        guard groupCount <= knownFlags.count else { throw WindogError.invalid("column flag map count exceeds definitions") }
        let rows = columns.map(\.count).max() ?? 0
        var result: [WindogFlagInterval] = []
        var seen: Set<UInt16> = []
        for _ in 0..<groupCount {
            let rawID = try integer(4)
            guard rawID <= UInt16.max, knownFlags.contains(UInt16(rawID)), seen.insert(UInt16(rawID)).inserted else {
                throw WindogError.invalid("column flag map references an unknown or duplicate flag")
            }
            let flagID = UInt16(rawID)
            guard try integer(4) == 0 else { throw WindogError.unsupported("flag interval collection schema") }
            let count = Int(try integer(4))
            guard count <= 1_000_000 - result.count, count <= max(0, limit - offset) / 10 else {
                throw WindogError.invalid("flag interval count exceeds archive bounds")
            }
            for _ in 0..<count {
                guard try integer(2) == 0 else { throw WindogError.unsupported("flag interval schema") }
                let first = Int(Int32(bitPattern: try integer(4)))
                let last = Int(Int32(bitPattern: try integer(4)))
                guard first >= 0, first <= last, last < rows else {
                    throw WindogError.invalid("flag interval is outside the dataset")
                }
                result.append(WindogFlagInterval(flagID: flagID, startIndex: first, endIndex: last))
            }
        }
        return result
    }
}

/// Inclusion semantics: a row is accepted when it has any selected flag, or
/// when it has no flags and includeUnflagged is enabled. Multiple flags are not
/// exclusive categories. Decoder validation is separate from this pure helper.
public enum WindogFlagSelection {
    public static func includedIndices(intervals: [WindogFlagInterval], rowCount: Int,
                                       includeUnflagged: Bool, flagIDs: Set<UInt16>) -> Set<Int> {
        guard rowCount > 0 else { return [] }
        var flagged = Array(repeating: false, count: rowCount)
        var included: Set<Int> = []
        for interval in intervals {
            let first = max(0, interval.startIndex)
            let last = min(rowCount - 1, interval.endIndex)
            guard first <= last else { continue }
            for row in first...last {
                flagged[row] = true
                if flagIDs.contains(interval.flagID) { included.insert(row) }
            }
        }
        if includeUnflagged {
            for row in 0..<rowCount where !flagged[row] { included.insert(row) }
        }
        return included
    }
}
