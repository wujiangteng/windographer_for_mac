import Foundation

public struct WAsPExportOptions: Sendable {
    public let speedID: String
    public let directionID: String
    public let sectors: Int
    public let binWidth: Double
    public let site: WindExportSite
    public let missingSentinel: Double?

    public init(speedID: String, directionID: String, sectors: Int = 16, binWidth: Double = 1,
                site: WindExportSite, missingSentinel: Double? = 9999) {
        self.speedID = speedID
        self.directionID = directionID
        self.sectors = sectors
        self.binWidth = binWidth
        self.site = site
        self.missingSentinel = missingSentinel
    }
}

public enum WAsPDataExporter {
    public static func write(_ dataset: WindExportDataSet, options: WAsPExportOptions, to url: URL) throws {
        try dataset.validate()
        try options.site.validate()
        guard options.site.height > 0, (1...72).contains(options.sectors),
              options.binWidth.isFinite, options.binWidth >= 0.1, options.binWidth <= 10,
              let speed = dataset.columns.first(where: { $0.id == options.speedID }),
              let direction = dataset.columns.first(where: { $0.id == options.directionID }),
              speed.id != direction.id, speed.unit == "m/s",
              ["deg", "°", "Deg"].contains(direction.unit),
              speed.values.count == direction.values.count else {
            throw WindogError.invalid("WAsP requires aligned m/s and degree columns, a positive height, 1–72 sectors and a 0.1–10 m/s bin width")
        }
        func pair(_ index: Int) -> (Double, Double)? {
            guard let s = speed.values[index], let d = direction.values[index],
                  s.isFinite, d.isFinite, s >= 0, (0...360).contains(d),
                  s != options.missingSentinel, d != options.missingSentinel else { return nil }
            return (s, d)
        }
        var maximumSpeed = 0.0
        var validCount = 0
        for index in speed.values.indices {
            if let (s, _) = pair(index) { maximumSpeed = max(maximumSpeed, s); validCount += 1 }
        }
        guard validCount > 0 else { throw WindogError.invalid("no valid wind-speed/direction pairs") }
        let binCountValue = max(1, ceil(maximumSpeed / options.binWidth))
        guard binCountValue <= 10_000 else { throw WindogError.invalid("too many WAsP speed bins; check missing codes or increase bin width") }
        let binCount = Int(binCountValue)
        var counts = Array(repeating: Array(repeating: 0, count: options.sectors), count: binCount)
        var totals = Array(repeating: 0, count: options.sectors)
        let sectorWidth = 360.0 / Double(options.sectors)
        for index in speed.values.indices {
            guard let (s, d) = pair(index) else { continue }
            let sector = Int(floor((d + sectorWidth / 2) / sectorWidth)) % options.sectors
            // Interior edge equality enters the next bin; the final edge is closed.
            let bin = min(binCount - 1, Int(floor(s / options.binWidth)))
            counts[bin][sector] += 1
            totals[sector] += 1
        }
        func decimal(_ value: Double, digits: Int) -> String {
            String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
        }
        let cleanName = dataset.name.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        // Keep the legacy climate file ASCII; the user-selected filename can still be Unicode.
        let name = cleanName.unicodeScalars.map { $0.isASCII ? String($0) : "_" }.joined()
        try ExportFileWriter.write(to: url) { writer in
            try writer.append("\(name) - WindLab stored-data frequency table\r\n")
            try writer.append("\t\(decimal(options.site.latitude, digits: 7))\t\(decimal(options.site.longitude, digits: 7))\t\(decimal(options.site.height, digits: 1))\r\n")
            // These are scale/rotation fields, not the selected histogram bin width.
            try writer.append("\t\t\(options.sectors)\t1.00\t0.00\r\n")
            try writer.append("\t\t\t" + totals.map { decimal(Double($0) * 100 / Double(validCount), digits: 7) }.joined(separator: "\t") + "\r\n")
            for bin in 0..<binCount {
                let values = (0..<options.sectors).map { sector in
                    totals[sector] == 0 ? "0.0000000" : decimal(Double(counts[bin][sector]) * 1000 / Double(totals[sector]), digits: 7)
                }
                try writer.append(decimal(Double(bin + 1) * options.binWidth, digits: 3) + "\t" + values.joined(separator: "\t") + "\r\n")
            }
        }
    }
}
