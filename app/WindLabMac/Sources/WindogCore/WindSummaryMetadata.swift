import Foundation

/// Nil means not read from the source, never an implicit zero-coordinate site.
public struct WindSummaryMetadata: Decodable, Sendable {
    public var latitude: Double?
    public var longitude: Double?
    public var elevation: Double?
    public var calmThreshold: Double?

    public init(latitude: Double? = nil, longitude: Double? = nil, elevation: Double? = nil, calmThreshold: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.calmThreshold = calmThreshold
    }
}

public enum WindColumnMetadata {
    public static func height(in label: String) -> Double? {
        guard let range = label.range(of: #"(?i)\d+(?:\.\d+)?\s*m"#, options: .regularExpression) else { return nil }
        return Double(label[range].dropLast().trimmingCharacters(in: .whitespaces))
    }

    public static func kind(label: String, unit: String) -> String {
        let lower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Angular coordinates are not wind sensors. Explicit column configuration
        // can still override this conservative inference.
        if ["n", "e", "lat", "lon", "latitude", "longitude", "northing", "easting"].contains(lower) { return "other" }
        if lower.range(of: #"^(?:wd|winddir)(?:[_\s\d-]|$)"#, options: .regularExpression) != nil { return "wind_direction" }
        if lower.contains("quality") || lower.contains("reliability") || label.contains("质量") || label.contains("可靠") { return "quality" }
        if lower.range(of: #"^rh(?:[_\s\d-]|$)"#, options: .regularExpression) != nil || lower.contains("humidity") || label.contains("湿度") || unit == "%RH" { return "humidity" }
        if lower.range(of: #"^ta(?:[_\s\d-]|$)"#, options: .regularExpression) != nil || ["C", "°C", "℃"].contains(unit) || lower.contains("temperature") || label.contains("温度") { return "temperature" }
        if ["kPa", "hPa", "Pa"].contains(unit) || lower.contains("pressure") || label.contains("气压") || label.contains("压力") { return "pressure" }
        if ["kg/m3", "kg/m³"].contains(unit) || lower.contains("air density") { return "density" }
        if ["W/m2", "W/m²"].contains(unit) || label.contains("功率密度") || lower.contains("wpd") { return "power_density" }
        if ["deg", "°", "Deg"].contains(unit) || lower.contains("direction") || label.contains("风向") { return "wind_direction" }
        if lower.contains("vertical") || lower.contains("vert.") || label.contains("垂直") || label.contains("z方向") { return "vertical_wind_speed" }
        if unit == "m/s" || label.contains("风速") { return "wind_speed" }
        return "other"
    }

    public static func subtype(in label: String) -> String {
        let lower = label.lowercased()
        if label.contains("标准差") || label.contains("偏差") || lower.contains("standard deviation") || lower.contains("std") || lower.range(of: #"(?:^|[\s_;])sd(?:$|[\s_;])"#, options: .regularExpression) != nil { return "Std. dev." }
        if label.contains("最大") || label.contains("极大") || lower.range(of: #"(?:^|[\s_;])max(?:$|[\s_;])"#, options: .regularExpression) != nil { return "Max" }
        if label.contains("最小") || label.contains("极小") || lower.range(of: #"(?:^|[\s_;])min(?:$|[\s_;])"#, options: .regularExpression) != nil { return "Min" }
        if label.contains("阵风") || lower.contains("gust") { return "Gust" }
        return "Mean"
    }
}
