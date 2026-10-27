import Foundation

public struct WindExportSite: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let height: Double

    public init(latitude: Double, longitude: Double, height: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
    }

    public func validate() throws {
        guard latitude.isFinite, longitude.isFinite, height.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude), height >= 0 else {
            throw WindogError.invalid("invalid latitude, longitude or measurement height")
        }
    }
}

public enum DelimitedDataExporter {
    public static func write(_ dataset: WindExportDataSet, format: WindExportFormat,
                             to destination: URL, missingValue: String = "-9999",
                             site: WindExportSite? = nil) throws {
        try dataset.validate()
        guard [.csv, .tsv, .windographerText].contains(format) else {
            throw WindogError.unsupported("not a delimited data-table format")
        }
        if let site { try site.validate() }
        let delimiter = format == .csv ? "," : "\t"
        let formatter = WindExportNumbers.dateFormatter()
        try ExportFileWriter.write(to: destination) { writer in
            if format == .csv { try writer.append("\u{feff}") }
            if format == .windographerText {
                try writer.append("Created \(formatter.string(from: Date())) by WindLab\r\n\r\n")
                if let site {
                    try writer.append("Latitude = \(WindExportNumbers.string(site.latitude))\r\n")
                    try writer.append("Longitude = \(WindExportNumbers.string(site.longitude))\r\n")
                    try writer.append("Measurement height = \(WindExportNumbers.string(site.height)) m\r\n\r\n")
                }
                try writer.append("Time stamps indicate the beginning of the time step.\r\n")
                try writer.append("Data policy: stored values; quality flags are not applied; computed-only columns are omitted.\r\n\r\n")
            }
            let headings = ["Date/Time"] + dataset.columns.map(\.heading)
            try writer.append(headings.map { field($0, delimiter: delimiter) }.joined(separator: delimiter) + "\r\n")
            for index in 0..<dataset.rowCount {
                let date = dataset.startDate.addingTimeInterval(Double(index) * Double(dataset.timeStepMinutes) * 60)
                var fields = [formatter.string(from: date)]
                for column in dataset.columns {
                    if index < column.values.count, let value = column.values[index], value.isFinite {
                        fields.append(WindExportNumbers.string(value))
                    } else {
                        fields.append(missingValue)
                    }
                }
                try writer.append(fields.map { field($0, delimiter: delimiter) }.joined(separator: delimiter) + "\r\n")
            }
        }
    }

    private static func field(_ value: String, delimiter: String) -> String {
        if value.contains(delimiter) || value.contains("\"") || value.contains("\r") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

/// Output is staged in the destination directory and committed only after all
/// rows have been written, so an error cannot truncate an existing export.
final class ExportFileWriter {
    private let handle: FileHandle
    private var buffer = Data()

    private init(handle: FileHandle) { self.handle = handle }

    func append(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= 65536 { try flush() }
    }

    private func flush() throws {
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
    }

    static func write(to destination: URL, body: (ExportFileWriter) throws -> Void) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".windlab-export-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw WindogError.invalid("cannot create export file")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            let writer = ExportFileWriter(handle: handle)
            try body(writer)
            try writer.flush()
            try handle.close()
            // rename(2) atomically replaces a file on the same filesystem.
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? handle.close()
            throw error
        }
    }
}
