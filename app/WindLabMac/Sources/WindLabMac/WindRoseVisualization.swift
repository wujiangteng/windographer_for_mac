import SwiftUI
import WindogCore

enum RosePlotStyle: String, CaseIterable {
    case line = "Line"
    case filled = "Filled"
    case bars = "Bars"
}

struct WindRoseResultTable: View {
    let result: RoseResult
    let display: RoseDisplay

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                if display == .scatter {
                    row(["Series", "Direction (°)", "Value", "Unit"], header: true)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(result.series.indices, id: \.self) { seriesIndex in
                            let series = result.series[seriesIndex]
                            ForEach(series.scatterPoints.indices, id: \.self) { index in
                                let point = series.scatterPoints[index]
                                row([series.label, HistogramPresentation.number(point.direction),
                                     HistogramPresentation.number(point.value), series.unit], header: false)
                            }
                        }
                    }
                } else {
                row(["Sector center (°)"] + result.series.map { "\($0.label) [\($0.unit)]" }, header: true)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(result.sectorCenters.indices, id: \.self) { index in
                        row([HistogramPresentation.number(result.sectorCenters[index])] + result.series.map {
                            guard index < $0.sectorValues.count, let value = $0.sectorValues[index] else { return "n/a" }
                            return HistogramPresentation.number(value, digits: display == .occurrences ? 0 : 4)
                        }, header: false)
                        .background(index.isMultiple(of: 2) ? Color(.controlBackgroundColor).opacity(0.35) : .clear)
                    }
                }
                }
            }.textSelection(.enabled)
        }
        .background(Color(.textBackgroundColor))
        .overlay(Rectangle().stroke(Color(.separatorColor)))
        .accessibilityLabel("Wind rose result table: \(result.sectorCenters.count) sectors, \(result.series.count) series")
    }

    private func row(_ values: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                Text(values[index])
                    .font(.system(size: 11, weight: header ? .semibold : .regular, design: .monospaced))
                    .frame(width: index == 0 ? 128 : 180, alignment: .trailing)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(header ? Color(.controlBackgroundColor) : .clear)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color(.separatorColor)).frame(width: 0.5) }
            }
        }.fixedSize(horizontal: true, vertical: false)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(.separatorColor)).frame(height: 0.5) }
    }

    static func tableText(result: RoseResult, display: RoseDisplay, delimiter: String = "\t") -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        if display == .scatter {
            var rows = [["Series", "Direction [deg]", "Value", "Unit"]]
            for series in result.series {
                for point in series.scatterPoints {
                    rows.append([series.label, HistogramPresentation.number(point.direction),
                                 HistogramPresentation.number(point.value), series.unit])
                }
            }
            return rows.map { $0.map(quote).joined(separator: delimiter) }.joined(separator: "\r\n") + "\r\n"
        }
        var rows = [["Sector center [deg]"] + result.series.map { "\($0.label) [\($0.unit)]" }]
        for index in result.sectorCenters.indices {
            rows.append([HistogramPresentation.number(result.sectorCenters[index])] + result.series.map {
                guard index < $0.sectorValues.count, let value = $0.sectorValues[index] else { return "n/a" }
                return HistogramPresentation.number(value, digits: display == .occurrences ? 0 : 6)
            })
        }
        return rows.map { $0.map(quote).joined(separator: delimiter) }.joined(separator: "\r\n") + "\r\n"
    }
}

/// Sector statistics are source values; this renderer applies only a common
/// labeled radial scale and a local projection. Native pixel geometry is not
/// asserted. In particular, negative statistics are drawn inside the zero ring.
struct WindRoseVisualization: View {
    let result: RoseResult
    let display: RoseDisplay
    let visibleIDs: Set<String>
    let style: RosePlotStyle
    var northOffset: Double = 0
    var showsGrid = true

    static func seriesColor(_ series: RoseSeriesResult, index: Int) -> Color {
        // Grouped series can share a source color; differentiate them by palette.
        if !series.id.contains("|"), let name = series.colorName { return .chartColor(name) }
        return HistogramVisualization.groupColor(index)
    }

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = max(10, min(size.width, size.height) / 2 - 46)
                let bounds = radialBounds
                if showsGrid { drawGrid(context: &context, center: center, radius: radius, bounds: bounds) }
                else if bounds.lowerBound < 0 {
                    let distance = (0 - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound) * radius
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - distance, y: center.y - distance,
                                                         width: distance * 2, height: distance * 2)),
                                   with: .color(.black.opacity(0.7)), lineWidth: 1.2)
                    context.draw(Text("0").font(.system(size: 10)),
                                 at: position(degrees: 165, value: 0, center: center, radius: radius, bounds: bounds))
                }
                drawDirections(context: &context, center: center, radius: radius)
                for (index, series) in result.series.enumerated() where visibleIDs.contains(series.id) {
                    let color = Self.seriesColor(series, index: index)
                    draw(series: series, color: color, context: &context, center: center, radius: radius, bounds: bounds)
                }
            }
            .accessibilityLabel("Wind rose \(display.rawValue), \(result.sectorCenters.count) sectors, \(unitCaption)")
            Text(unitCaption).font(.caption).foregroundStyle(.secondary)
        }.padding(6).background(.white)
    }

    private var visible: [RoseSeriesResult] { result.series.filter { visibleIDs.contains($0.id) } }
    private var radialBounds: ClosedRange<Double> {
        let values = visible.flatMap { series in
            display == .scatter ? series.scatterPoints.map(\.value) : series.sectorValues.compactMap { $0 }
        }.filter(\.isFinite)
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 0, 0)
        let ticks = niceTicks(minimum: low, maximum: high == low ? low + 1 : high)
        return (ticks.first ?? 0)...max((ticks.first ?? 0) + 1e-12, ticks.last ?? 1)
    }
    private var unitCaption: String {
        let units = Set(visible.map(\.unit)).sorted()
        let unit = units.isEmpty ? "" : " [\(units.joined(separator: ", "))]"
        let name: String = switch display {
        case .occurrences: "Occurrences"
        case .frequency: "Frequency"
        case .mean: "Mean"
        case .minimum: "Minimum"
        case .maximum: "Maximum"
        case .standardDeviation: "Standard deviation"
        case .totalEnergy: "Proportion of total wind energy"
        case .scatter: "Stored sample values"
        }
        return radialBounds.lowerBound < 0 ? "\(name)\(unit) · zero ring marked" : name + unit
    }

    private func position(degrees: Double, value: Double, center: CGPoint, radius: Double, bounds: ClosedRange<Double>) -> CGPoint {
        let fraction = (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
        let angle = (degrees + northOffset - 90) * .pi / 180
        return CGPoint(x: center.x + cos(angle) * fraction * radius,
                       y: center.y + sin(angle) * fraction * radius)
    }
    private func drawGrid(context: inout GraphicsContext, center: CGPoint, radius: Double, bounds: ClosedRange<Double>) {
        for value in niceTicks(minimum: bounds.lowerBound, maximum: bounds.upperBound) where bounds.contains(value) {
            let distance = (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound) * radius
            let circle = CGRect(x: center.x - distance, y: center.y - distance, width: distance * 2, height: distance * 2)
            context.stroke(Path(ellipseIn: circle), with: .color(value == 0 ? .black.opacity(0.7) : .gray.opacity(0.4)),
                           style: StrokeStyle(lineWidth: value == 0 ? 1.2 : 0.7, dash: value == 0 ? [] : [4, 5]))
            let label = HistogramPresentation.number(value) + ((display == .frequency || display == .totalEnergy) ? " %" : "")
            let point = position(degrees: 165, value: value, center: center, radius: radius, bounds: bounds)
            context.draw(Text(label).font(.system(size: 10)), at: point, anchor: .center)
        }
        let step = max(1, Int(ceil(Double(result.sectorCenters.count) / 16)))
        for index in stride(from: 0, to: result.sectorCenters.count, by: step) {
            let outer = position(degrees: result.sectorCenters[index], value: bounds.upperBound, center: center, radius: radius, bounds: bounds)
            var path = Path(); path.move(to: center); path.addLine(to: outer)
            context.stroke(path, with: .color(.gray.opacity(0.3)), style: StrokeStyle(lineWidth: 0.7, dash: [4, 5]))
        }
    }
    private func drawDirections(context: inout GraphicsContext, center: CGPoint, radius: Double) {
        let step = max(1, Int(ceil(Double(result.sectorCenters.count) / 16)))
        let compass = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        for index in stride(from: 0, to: result.sectorCenters.count, by: step) {
            let degrees = result.sectorCenters[index]
            let compassIndex = Int((degrees / 22.5).rounded()) % 16
            let exact = abs(degrees / 22.5 - (degrees / 22.5).rounded()) < 1e-8
            let label = exact ? compass[compassIndex] : HistogramPresentation.number(degrees) + "°"
            let angle = (degrees + northOffset - 90) * .pi / 180
            context.draw(Text(label).font(.system(size: 11)),
                         at: CGPoint(x: center.x + cos(angle) * (radius + 22), y: center.y + sin(angle) * (radius + 22)))
        }
    }
    private func draw(series: RoseSeriesResult, color: Color, context: inout GraphicsContext,
                      center: CGPoint, radius: Double, bounds: ClosedRange<Double>) {
        if display == .scatter {
            var circles = Path()
            for point in series.scatterPoints where point.direction.isFinite && point.value.isFinite {
                let position = position(degrees: point.direction, value: point.value, center: center, radius: radius, bounds: bounds)
                circles.addEllipse(in: CGRect(x: position.x - 1.2, y: position.y - 1.2, width: 2.4, height: 2.4))
            }
            context.fill(circles, with: .color(color.opacity(0.65)))
            return
        }
        let count = min(result.sectorCenters.count, series.sectorValues.count)
        guard count > 0 else { return }
        if style == .bars {
            let halfWidth = 360 / Double(count) * 0.42
            let zero = (0 - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound) * radius
            for index in 0..<count {
                guard let value = series.sectorValues[index], value.isFinite else { continue }
                let distance = (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound) * radius
                let low = min(zero, distance), high = max(zero, distance)
                let start = Angle.degrees(result.sectorCenters[index] + northOffset - 90 - halfWidth)
                let end = Angle.degrees(result.sectorCenters[index] + northOffset - 90 + halfWidth)
                var wedge = Path()
                wedge.addArc(center: center, radius: high, startAngle: start, endAngle: end, clockwise: false)
                wedge.addArc(center: center, radius: low, startAngle: end, endAngle: start, clockwise: true)
                wedge.closeSubpath()
                context.fill(wedge, with: .color(color.opacity(0.5)))
                context.stroke(wedge, with: .color(color), lineWidth: 0.8)
            }
            return
        }
        var path = Path()
        var started = false
        for index in 0..<count {
            guard let value = series.sectorValues[index], value.isFinite else { started = false; continue }
            let point = position(degrees: result.sectorCenters[index], value: value, center: center, radius: radius, bounds: bounds)
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        if let first = series.sectorValues.first ?? nil, let last = series.sectorValues[count - 1], first.isFinite, last.isFinite {
            path.addLine(to: position(degrees: result.sectorCenters[0], value: first, center: center, radius: radius, bounds: bounds))
        }
        // Filling a path with gaps would implicitly close and bridge missing
        // sectors. Only complete sector loops are eligible for filled polygons.
        if style == .filled && series.sectorValues.prefix(count).allSatisfy({ $0?.isFinite == true }) {
            var filled = path; filled.closeSubpath()
            context.fill(filled, with: .color(color.opacity(0.18)))
        }
        context.stroke(path, with: .color(color), lineWidth: 1.8)
        for index in 0..<count {
            guard let value = series.sectorValues[index], value.isFinite else { continue }
            let previous = series.sectorValues[(index + count - 1) % count]
            let next = series.sectorValues[(index + 1) % count]
            if previous == nil && next == nil {
                let point = position(degrees: result.sectorCenters[index], value: value, center: center, radius: radius, bounds: bounds)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(color))
            }
        }
    }
    private func niceTicks(minimum: Double, maximum: Double) -> [Double] {
        let span = max(maximum - minimum, 1e-12)
        let power = pow(10, floor(log10(span / 4)))
        let scaled = span / 4 / power
        let rawStep = (scaled <= 1 ? 1 : scaled <= 2 ? 2 : scaled <= 5 ? 5 : 10) * power
        let step = display == .occurrences ? max(1, rawStep) : rawStep
        let low = floor(minimum / step) * step
        let high = ceil(maximum / step) * step
        return stride(from: low, through: high + step * 1e-6, by: step).map { abs($0) < step * 1e-8 ? 0 : $0 }
    }
}
