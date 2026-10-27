import Foundation

public struct WeibullFit: Sendable {
    public let shape: Double
    public let scale: Double

    public init(shape: Double, scale: Double) {
        self.shape = shape
        self.scale = scale
    }

    public var mean: Double { scale * tgamma(1 + 1 / shape) }
    public var thirdMoment: Double { pow(scale, 3) * tgamma(1 + 3 / shape) }

    public func survival(_ speed: Double) -> Double {
        speed <= 0 ? 1 : exp(-pow(speed / scale, shape))
    }

    public func density(_ speed: Double) -> Double {
        guard speed > 0 else { return 0 }
        let exponent = shape * log(speed / scale)
        guard exponent < 700 else { return 0 }
        return exp(log(shape / scale) + (shape - 1) * log(speed / scale) - exp(exponent))
    }
}

public enum WeibullMethod: String, CaseIterable, Sendable {
    case maximumLikelihood = "Maximum likelihood"
    case leastSquares = "Least squares"
    case wasp = "WAsP"
}

public struct WindDistributionBin: Sendable {
    public let lower: Double
    public let upper: Double
    public let count: Int
    public let percentage: Double
    public var center: Double { (lower + upper) / 2 }
    public var width: Double { upper - lower }
}

public struct WindDistributionFit: Sendable {
    public let method: WeibullMethod
    public let parameters: WeibullFit?
    public let rSquared: Double?
}

public struct WindDistributionResult: Sendable {
    public let bins: [WindDistributionBin]
    public let fits: [WindDistributionFit]
    public let sampleCount: Int
    public let mean: Double
    public let meanCube: Double
    public let proportionAboveMean: Double
    public let airDensity: Double
    public var powerDensity: Double { 0.5 * airDensity * meanCube }
}

/// Reconstructs Windographer 4.0.24 analysis, rather than preserving the previous
/// Python approximation. Native addresses and remaining limits are documented in
/// analysis/windographer-4.0.241-weibull/.
public enum WeibullAnalysis {
    /// Histogram uses only the recovered MLE fit; display bins do not enter it.
    public static func maximumLikelihood(_ input: [Double]) -> WeibullFit? {
        NativeWeibullMaximumLikelihood.fit(input.filter { $0.isFinite && $0 >= 0 && $0 != 9999 }.sorted())
    }

    public static func analyze(_ input: [Double], binWidth: Double? = nil, binStart: Double? = nil,
                               halfFirstBin: Bool = false, airDensity: Double = 1.225) throws -> WindDistributionResult {
        guard airDensity.isFinite, airDensity > 0 else { throw WindogError.invalid("invalid air density") }
        let values = input.filter { $0.isFinite && $0 >= 0 && $0 != 9999 }.sorted()
        guard !values.isEmpty else { throw WindogError.invalid("no valid wind-speed samples match the selected filters") }
        let mean = values.reduce(0, +) / Double(values.count)
        let meanCube = values.reduce(0) { $0 + $1 * $1 * $1 } / Double(values.count)
        guard meanCube.isFinite else { throw WindogError.invalid("wind-speed moments exceed numerical bounds") }
        let proportion = Double(values.filter { $0 > mean }.count) / Double(values.count)
        let automatic = automaticGrid(values)
        let span = automatic.width * Double(automatic.count)
        let width = binWidth.map { $0 > 0 && span / $0 <= 500.1 ? $0 : automatic.width } ?? automatic.width
        if let binWidth, !binWidth.isFinite || binWidth <= 0 { throw WindogError.invalid("bin width must be positive") }
        let start = binStart ?? automatic.start
        let bins = try histogram(values, width: width, start: start, halfFirstBin: halfFirstBin,
                                 upperBound: automatic.start + span)
        let parameters: [(WeibullMethod, WeibullFit?)] = [
            (.maximumLikelihood, NativeWeibullMaximumLikelihood.fit(values)),
            (.leastSquares, leastSquares(values)),
            (.wasp, wasp(values))
        ]
        let fits = parameters.map { method, fit in
            WindDistributionFit(method: method, parameters: fit,
                                rSquared: fit.map { goodnessOfFit(values, fit: $0) })
        }
        return WindDistributionResult(bins: bins, fits: fits, sampleCount: values.count,
                                      mean: mean, meanCube: meanCube, proportionAboveMean: proportion, airDensity: airDensity)
    }

    /// 0x523500: regress log(-log(1-F)) on log(v), F=(i+0.5)/n.
    /// Negative transformed coordinates are valid and MUST NOT be discarded.
    public static func leastSquares(_ input: [Double]) -> WeibullFit? {
        let sorted = input.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard sorted.count >= 2 else { return nil }
        let n = Double(sorted.count)
        var points: [(Double, Double)] = []
        for (index, speed) in sorted.enumerated() where speed > 0 {
            let f = min(0.999999, max(0.000001, (Double(index) + 0.5) / n))
            points.append((log(speed), log(-log1p(-f))))
        }
        guard points.count >= 2 else { return nil }
        let meanX = points.reduce(0) { $0 + $1.0 } / Double(points.count)
        let meanY = points.reduce(0) { $0 + $1.1 } / Double(points.count)
        let variance = points.reduce(0) { $0 + pow($1.0 - meanX, 2) }
        guard variance > 1e-24 else { return nil }
        let slope = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / variance
        let intercept = meanY - slope * meanX
        return validFit(shape: slope, scale: exp(-intercept / slope))
    }

    /// 0x522dd0 / 0x523bc0: match the third moment and empirical exceedance
    /// at the measured mean. This is not a mean/third-moment EPF fit.
    public static func wasp(_ input: [Double]) -> WeibullFit? {
        let values = input.filter { $0.isFinite && $0 >= 0 }
        guard values.count >= 10 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let cube = values.reduce(0) { $0 + $1 * $1 * $1 } / Double(values.count)
        let p = Double(values.filter { $0 > mean }.count) / Double(values.count)
        guard mean > 0, cube > 0, cube.isFinite, p > 0, p < 1 else { return nil }
        func scale(_ shape: Double) -> Double { exp((log(cube) - lgamma(1 + 3 / shape)) / 3) }
        func objective(_ shape: Double) -> Double {
            pow(mean / scale(shape), shape) + log(p)
        }
        var lower = 0.2
        var upper = 4.0
        var lowValue = objective(lower)
        var highValue = objective(upper)
        var attempts = 0
        while lowValue * highValue > 0, attempts < 100 {
            upper += 1
            highValue = objective(upper)
            attempts += 1
        }
        guard lowValue.isFinite, highValue.isFinite, lowValue * highValue <= 0 else { return nil }
        for _ in 0..<100 {
            let middle = (lower + upper) / 2
            let value = objective(middle)
            if abs(value) < 1e-12 || upper - lower < 1e-10 {
                return validFit(shape: middle, scale: scale(middle))
            }
            if lowValue * value <= 0 { upper = middle }
            else { lower = middle; lowValue = value }
        }
        let shape = (lower + upper) / 2
        return validFit(shape: shape, scale: scale(shape))
    }

    static func validFit(shape: Double, scale: Double) -> WeibullFit? {
        guard shape.isFinite, scale.isFinite, shape > 0, scale > 0 else { return nil }
        return WeibullFit(shape: shape, scale: scale)
    }

    private static func histogram(_ values: [Double], width: Double, start: Double,
                                  halfFirstBin: Bool, upperBound: Double) throws -> [WindDistributionBin] {
        guard width.isFinite, width > 0, start.isFinite, start >= 0 else {
            throw WindogError.invalid("bin width must be positive and bin start nonnegative")
        }
        let maximum = max(upperBound, start)
        let firstWidth = halfFirstBin ? width / 2 : width
        let estimate = max(1, 1 + ceil(max(0, maximum - start - firstWidth) / width))
        guard estimate <= 10_000 else { throw WindogError.invalid("too many histogram bins; increase the width") }
        let count = Int(estimate)
        var counts = Array(repeating: 0, count: count)
        let lastEdge = start + firstWidth + Double(count - 1) * width
        for value in values where value >= start && value <= lastEdge {
            let index = value < start + firstWidth ? 0 : min(count - 1, 1 + Int((value - start - firstWidth) / width))
            counts[index] += 1
        }
        // Restricting the displayed range does not redefine the fitting sample.
        return counts.enumerated().map { index, occurrences in
            let lower = index == 0 ? start : start + firstWidth + Double(index - 1) * width
            let upper = index == 0 ? start + firstWidth : lower + width
            return WindDistributionBin(lower: lower, upper: upper, count: occurrences,
                                       percentage: Double(occurrences) * 100 / Double(values.count))
        }
    }

    /// 0x50c910/0x50e590 choose a nice range; 0x50cef0 chooses 40–80 bins.
    /// The resulting count is independent of the user-selected histogram width.
    static func automaticGrid(_ values: [Double]) -> (start: Double, width: Double, count: Int) {
        guard let minimum = values.min(), let maximum = values.max() else { return (0, 0.025, 40) }
        var lower = minimum
        var upper = maximum
        if gridNearlyEqual(lower, upper, tolerance: 0.0001) {
            if abs(lower) <= 0.0001 { upper = 1 }
            else if lower > 0 { upper = lower * 1.5; lower *= 0.5 }
            else { lower *= 1.5; upper *= 0.5 }
        }
        var steps = gridNiceSteps(lower: lower, upper: upper)
        lower = floor(lower / steps.major) * steps.major
        if !gridMultiple(upper, of: steps.major) { upper = (trunc(upper / steps.major) + 1) * steps.major }
        // Native recomputes the major step after the first outward rounding.
        steps = gridNiceSteps(lower: lower, upper: upper)
        if !gridMultiple(lower, of: steps.major) { lower = floor(lower / steps.major) * steps.major }
        if !gridMultiple(upper, of: steps.major) { upper = (trunc(upper / steps.major) + 1) * steps.major }
        let span = max(upper - lower, Double.leastNormalMagnitude)
        let countSteps = gridNiceSteps(lower: lower, upper: upper)
        var count = Int((span / countSteps.minor).rounded(.toNearestOrAwayFromZero))
        if count < 1 { count = 4 }
        if count < 40 {
            while count < 40 { count *= 2 }
        } else if count > 80 {
            while count > 80 {
                if count % 2 != 0, count % 3 == 0 { count /= 3 }
                else if count % 2 != 0, count % 5 == 0 { count /= 5 }
                else { count /= 2 }
            }
        }
        if count < 40 || count > 80 {
            count = Int((span / countSteps.major).rounded(.toNearestOrAwayFromZero))
            if count < 1 { count = 4 }
            while count < 40 { count *= 2 }
            while count > 80 { count /= 2 }
            if count < 40 || count > 80 { count = 40 }
        }
        return (lower, span / Double(count), count)
    }

    private static func gridNearlyEqual(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
        if a == 0 { return abs(b) <= tolerance }
        if b == 0 { return abs(a) <= tolerance }
        return abs((a - b) / a) <= tolerance
    }

    /// 0x50c220: compare a value with the nearest integral multiple, using
    /// relative 1e-6 tolerance rather than an unscaled absolute epsilon.
    private static func gridMultiple(_ value: Double, of step: Double) -> Bool {
        let rounded = (value / step).rounded(.toNearestOrAwayFromZero) * step
        return gridNearlyEqual(value, rounded, tolerance: 0.000001)
    }

    /// 0x50cbb0. The two returned steps have distinct roles: outward range
    /// rounding and candidate bin counts. They are not a single 1/2/5 ladder.
    private static func gridNiceSteps(lower: Double, upper: Double) -> (major: Double, minor: Double) {
        var span = upper - lower
        if span == 0 { span = 1 }
        let magnitude = pow(10, max(-15, floor(log10(abs(span)))))
        if lower >= 0, lower <= 1, upper >= 359, upper <= 360 { return (30, 10) }
        let quarter = 2.5 * span / magnitude
        if gridMultiple(lower, of: 4), gridMultiple(upper, of: 4), [3.0, 4, 6, 8].contains(quarter) {
            return (quarter * magnitude / 10, magnitude / 10)
        }
        let scaled = 2 * span / magnitude
        let primary: Double
        let secondary: Double
        if scaled < 3 { primary = 2; secondary = 1 }
        else if scaled == 3 { primary = 5; secondary = 1 }
        else if scaled < 4 { primary = 4; secondary = 1 }
        else if scaled < 7.5 { primary = 5; secondary = 1 }
        else if scaled < 15 { primary = 10; secondary = 5 }
        else { primary = 20; secondary = 5 }
        return (primary * magnitude / 10, secondary * magnitude / 10)
    }

    /// 0x523930: integrate fitted/empirical CDFs over an independent automatic
    /// 40–80-bin grid. User histogram width does not change this statistic.
    public static func goodnessOfFit(_ sortedValues: [Double], fit: WeibullFit) -> Double {
        let values = sortedValues.sorted()
        guard !values.isEmpty else { return 0 }
        let grid = automaticGrid(values)
        var observed: [Double] = []
        var predicted: [Double] = []
        var cursor = 0
        // 0x51e990 evaluates the empirical CDF at every edge, including zero.
        // Subtracting F(0) keeps exact zero observations out of the first
        // differenced interval, matching the native statistic.
        while cursor < values.count, values[cursor] <= 0 { cursor += 1 }
        var previousCDF = Double(cursor) / Double(values.count)
        var previousFit = 1 - fit.survival(0)
        for bin in 1...grid.count {
            let edge = Double(bin) * grid.width
            while cursor < values.count, values[cursor] <= edge { cursor += 1 }
            let cdf = Double(cursor) / Double(values.count)
            let fitted = 1 - fit.survival(edge)
            observed.append(cdf - previousCDF)
            predicted.append(fitted - previousFit)
            previousCDF = cdf
            previousFit = fitted
        }
        let average = observed.reduce(0, +) / Double(observed.count)
        let total = observed.reduce(0) { $0 + pow($1 - average, 2) }
        guard total > 0 else { return 0 }
        let residual = zip(observed, predicted).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
        return 1 - residual / total
    }
}
