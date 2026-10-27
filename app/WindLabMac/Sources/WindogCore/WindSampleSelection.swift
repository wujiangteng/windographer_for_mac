import Foundation

public struct WindSampleSelection: Sendable {
    public var year: Int?
    public var month: Int?
    public var startDate: Date?
    /// Exclusive upper boundary; date-only controls pass the next midnight.
    public var endDate: Date?
    public var columnID: String?
    public var minimum: Double?
    public var maximum: Double?

    public init(year: Int? = nil, month: Int? = nil, startDate: Date? = nil, endDate: Date? = nil,
                columnID: String? = nil, minimum: Double? = nil, maximum: Double? = nil) {
        self.year = year
        self.month = month
        self.startDate = startDate
        self.endDate = endDate
        self.columnID = columnID
        self.minimum = minimum
        self.maximum = maximum
    }

    public func values(in dataset: WindExportDataSet, speedID: String) throws -> [Double] {
        try dataset.validate()
        guard let speed = dataset.columns.first(where: { $0.id == speedID }), speed.unit == "m/s" else {
            throw WindogError.invalid("select an available wind-speed column in m/s")
        }
        if let month, !(1...12).contains(month) { throw WindogError.invalid("invalid month") }
        if let year, !(1...9999).contains(year) { throw WindogError.invalid("invalid year") }
        if let minimum, !minimum.isFinite { throw WindogError.invalid("invalid lower filter limit") }
        if let maximum, !maximum.isFinite { throw WindogError.invalid("invalid upper filter limit") }
        if let minimum, let maximum, minimum > maximum { throw WindogError.invalid("minimum exceeds maximum") }
        if let startDate, !startDate.timeIntervalSince1970.isFinite { throw WindogError.invalid("invalid start date") }
        if let endDate, !endDate.timeIntervalSince1970.isFinite { throw WindogError.invalid("invalid end date") }
        if let startDate, let endDate, startDate >= endDate { throw WindogError.invalid("invalid date range") }
        let filter: WindExportColumn?
        if let columnID {
            guard let column = dataset.columns.first(where: { $0.id == columnID }) else {
                throw WindogError.invalid("filter column is unavailable")
            }
            filter = column
        } else {
            filter = nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var values: [Double] = []
        values.reserveCapacity(speed.values.count)
        for index in speed.values.indices {
            guard let value = speed.values[index], value.isFinite, value >= 0, value != 9999 else { continue }
            let date = dataset.startDate.addingTimeInterval(Double(index) * Double(dataset.timeStepMinutes) * 60)
            if let startDate, date < startDate { continue }
            if let endDate, date >= endDate { continue }
            if let year, calendar.component(.year, from: date) != year { continue }
            if let month, calendar.component(.month, from: date) != month { continue }
            if let filter {
                guard index < filter.values.count, let candidate = filter.values[index], candidate.isFinite else { continue }
                if let minimum, candidate < minimum { continue }
                if let maximum, candidate > maximum { continue }
            }
            values.append(value)
        }
        return values
    }
}
