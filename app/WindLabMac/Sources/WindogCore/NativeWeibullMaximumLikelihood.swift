import Foundation

/// Reconstruction of 4.0.24's 0x523e60 -> 0x525e80 path. The native routine
/// corrects its low tail with seeded truncated-Weibull draws; it is not ordinary
/// zero-clamped maximum likelihood. Address comments refer to the inspected x86 PE.
enum NativeWeibullMaximumLikelihood {
    static func fit(_ values: [Double]) -> WeibullFit? {
        guard values.count >= 2, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Double(Float.greatestFiniteMagnitude) }) else {
            return nil
        }
        let input = values.map(Float.init)
        guard let cutoff = lowSpeedCutoff(input) else { return nil }
        let high = input.filter { $0 >= cutoff }
        let lowCount = input.count - high.count
        guard var parameters = fixedPoint(high) else { return nil }
        var random = Ran0(seed: -4723) // 0x525eb2, persistent across outer iterations.
        // 0x526064 limits the correction loop to 20 refits. Even with no low
        // observations the native routine performs its first correction/refit.
        for _ in 0..<20 {
            let ratio = cutoff / parameters.scale
            let power = Float(pow(Double(ratio), Double(parameters.shape)))
            let probability = Float(1) - Float(exp(-Double(power)))
            guard probability.isFinite, probability >= 0, probability <= 1 else { return nil }
            var working = high
            working.reserveCapacity(input.count)
            for _ in 0..<lowCount {
                // Inverse truncated CDF, implemented by the native 0x526510.
                let product = random.next() * probability
                let logValue = -log(1 - Double(product))
                guard logValue > 0, logValue.isFinite else { return nil }
                let draw = parameters.scale * Float(exp(log(logValue) / Double(parameters.shape)))
                guard draw.isFinite, draw > 0 else { return nil }
                working.append(draw)
            }
            let previous = parameters.shape
            guard let next = fixedPoint(working) else { return nil }
            parameters = next
            if abs(parameters.shape - previous) / previous < Float(0.001) { break }
        }
        return WeibullFit(shape: Double(parameters.shape), scale: Double(parameters.scale))
    }

    private struct Parameters {
        let shape: Float
        let scale: Float
    }

    /// 0x523e90/0x526260: fixed-point positive-value likelihood update, k starts
    /// at 2, caps at 10, stops at relative change .001 or 100 iterations.
    private static func fixedPoint(_ values: [Float]) -> Parameters? {
        guard values.count >= 2 else { return nil }
        var shape = Float(2)
        for _ in 0..<100 {
            var weightedLogs = 0.0
            var powers = 0.0
            var logs = 0.0
            var count = 0
            for value in values where value > 0 {
                let power = Double(Float(pow(Double(value), Double(shape))))
                let logarithm = Double(Float(log(Double(value))))
                guard power.isFinite, logarithm.isFinite else { return nil }
                weightedLogs += power * logarithm
                powers += power
                logs += logarithm
                count += 1
            }
            guard count >= 2, powers > 0 else { return nil }
            let denominator = weightedLogs / powers - logs / Double(count)
            guard denominator > 0, denominator.isFinite else { return nil }
            let next = min(Float(1 / denominator), Float(10))
            guard next.isFinite, next > 0 else { return nil }
            let change = abs(next - shape) / shape
            shape = next
            if change < Float(0.001) { break }
        }
        // Native scale accumulation is float precision, unlike the double
        // accumulators used by its shape update.
        var sum = Float(0)
        for value in values where value >= 0 {
            sum += Float(pow(Double(value), Double(shape)))
        }
        let meanPower = sum / Float(values.count)
        let scale = Float(pow(Double(meanPower), Double(Float(1) / shape)))
        guard scale.isFinite, scale > 0 else { return nil }
        return Parameters(shape: shape, scale: scale)
    }

    /// 0x526370: inverse 0.5-percent point of a 200-point sampled CDF, clamped
    /// to the smallest positive observation. 0x534610 zero-initializes a vector
    /// resized to the original count, after which only positives are copied.
    private static func lowSpeedCutoff(_ values: [Float]) -> Float? {
        let positives = values.filter { $0 > 0 }
        guard let minimum = positives.min() else { return nil }
        var work = positives + Array(repeating: Float(0), count: values.count - positives.count)
        work.sort()
        let spread = work[work.count - 1] - work[0]
        guard spread.isFinite else { return nil }
        if spread == 0 { return minimum }
        let low = work[0] - spread * Float(0.0001)
        let high = work[work.count - 1] + spread * Float(0.0001)
        let width = (high - low) / Float(199)
        guard width.isFinite else { return nil }
        let grid = (0..<200).map { low + Float($0) * width }
        var cdf: [Float] = []
        cdf.reserveCapacity(200)
        var count = 0
        for edge in grid {
            while count < work.count, work[count] <= edge { count += 1 }
            cdf.append(Float(count) * Float(100) / Float(work.count))
        }
        // 0x50d690 interpolates between adjacent CDF samples at x=.5.
        var index = 0
        while index < 198, cdf[index + 1] <= Float(0.5) { index += 1 }
        let delta = cdf[index + 1] - cdf[index]
        let quantile: Float
        if abs(delta) < Float(1e-10) {
            quantile = (grid[index] + grid[index + 1]) * Float(0.5)
        } else if Float(0.5) <= cdf[index] {
            quantile = grid[index]
        } else if Float(0.5) >= cdf[index + 1] {
            quantile = grid[index + 1]
        } else {
            let fraction = (Float(0.5) - cdf[index]) / delta
            quantile = (Float(1) - fraction) * grid[index] + fraction * grid[index + 1]
        }
        return max(minimum, quantile)
    }

    /// 0x514390: Numerical Recipes ran0 / Park-Miller with XOR mask. This
    /// deliberately uses the native signed seed rather than abs(seed).
    private struct Ran0 {
        var seed: Int64

        mutating func next() -> Float {
            seed ^= 123459876
            let quotient = seed / 127773 // Swift integer division truncates toward zero.
            seed = 16807 * (seed - quotient * 127773) - 2836 * quotient
            if seed < 0 { seed += 2147483647 }
            let value = Float(Double(seed) / 2147483647)
            seed ^= 123459876
            return value
        }
    }
}
