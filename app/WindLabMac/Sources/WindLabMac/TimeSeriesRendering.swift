import Foundation

/// A display-only envelope; statistics continue to use the complete source.
/// Input points are ordered by their finite x coordinate. Missing y values are
/// explicit path breaks and never participate in extrema or averaging.
enum TimeSeriesRendering {
    static func reduce(points: [SeriesPoint], range: ClosedRange<Double>, pixelWidth: Int) -> [SeriesPoint] {
        guard !points.isEmpty, range.lowerBound.isFinite, range.upperBound.isFinite else { return [] }
        let width = max(1, pixelWidth)
        let span = range.upperBound - range.lowerBound

        func bound(_ value: Double, inclusive: Bool) -> Int {
            var low = 0
            var high = points.count
            while low < high {
                let middle = low + (high - low) / 2
                let x = points[middle].x
                if x < value || (inclusive && x == value) { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        // Retain immediate neighbours so clipping does not truncate segments
        // which cross a viewport edge without having a vertex inside it.
        let first = max(0, bound(range.lowerBound, inclusive: false) - 1)
        let end = min(points.count, bound(range.upperBound, inclusive: true) + 1)
        guard first < end else { return [] }
        var output: [SeriesPoint] = []
        output.reserveCapacity(min(end - first, width > Int.max / 4 ? end - first : width * 4))
        var bin = -1
        var firstIndex = first
        var lastIndex = first
        var minIndex = first
        var maxIndex = first
        var previousWasMissing = false

        func pixelBin(_ x: Double) -> Int {
            guard span > 0 else { return 0 }
            let fraction = (x - range.lowerBound) / span
            if fraction <= 0 { return 0 }
            if fraction >= 1 { return width - 1 }
            return min(width - 1, Int(fraction * Double(width)))
        }
        func flush() {
            guard bin >= 0 else { return }
            // Sort source indices rather than values to preserve chronology,
            // including opposite extrema within the same screen pixel.
            let candidates = [firstIndex, minIndex, maxIndex, lastIndex].sorted()
            var previous = -1
            for index in candidates where index != previous {
                output.append(points[index])
                previous = index
            }
            bin = -1
        }
        for index in first..<end {
            let point = points[index]
            guard point.x.isFinite, point.y.isFinite else {
                flush()
                if !previousWasMissing { output.append(point) }
                previousWasMissing = true
                continue
            }
            previousWasMissing = false
            let nextBin = pixelBin(point.x)
            if nextBin != bin {
                flush()
                bin = nextBin
                firstIndex = index
                minIndex = index
                maxIndex = index
            } else {
                if point.y < points[minIndex].y { minIndex = index }
                if point.y > points[maxIndex].y { maxIndex = index }
            }
            lastIndex = index
        }
        flush()
        return output
    }
}
