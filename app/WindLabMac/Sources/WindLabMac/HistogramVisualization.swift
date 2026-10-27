import SwiftUI
import WindogCore

enum HistogramSurfaceStyle: String, CaseIterable {
    case surface = "Surface"
    case heatmap = "Heat map"
}

struct HistogramResultTable: View {
    let presentation: HistogramPresentation
    let frequency: Bool

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(["Lower", "Upper"] + presentation.result.groups.map(\.label), header: true)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(presentation.result.bins.indices, id: \.self) { index in
                        let bin = presentation.result.bins[index]
                        tableRow([HistogramPresentation.number(bin.lower), HistogramPresentation.number(bin.upper)]
                                 + presentation.result.groups.indices.map {
                            HistogramPresentation.number(presentation.value(row: index, group: $0,
                                                                            frequency: frequency, table: true),
                                                         digits: frequency ? 4 : 0)
                        }, header: false)
                        .background(index.isMultiple(of: 2) ? Color(.controlBackgroundColor).opacity(0.35) : .clear)
                    }
                }
            }.textSelection(.enabled)
        }
        .background(Color(.textBackgroundColor))
        .overlay(Rectangle().stroke(Color(.separatorColor)))
        .accessibilityLabel("Histogram result table: \(presentation.result.bins.count) bins, \(presentation.result.groups.count) groups")
    }

    private func tableRow(_ values: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                Text(values[index])
                    .font(.system(size: 11, weight: header ? .semibold : .regular, design: .monospaced))
                    .frame(width: index < 2 ? 92 : 112, alignment: .trailing)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(header ? Color(.controlBackgroundColor) : .clear)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color(.separatorColor)).frame(width: 0.5) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(.separatorColor)).frame(height: 0.5) }
    }
}

struct HistogramVisualization: View {
    let presentation: HistogramPresentation
    let frequency: Bool
    let showFit: Bool
    let visibleGroups: Set<Int>
    let showAggregate: Bool
    var surfaceStyle: Binding<HistogramSurfaceStyle>? = nil
    var showsControls = true
    @State private var localSurfaceStyle = HistogramSurfaceStyle.surface

    static func groupColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .green, .red, .purple, .brown, .cyan, .pink,
                               .indigo, .mint, .teal, .yellow]
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    var body: some View {
        VStack(spacing: 4) {
            if presentation.grouping == .column {
                HStack {
                    Text(presentation.secondaryLabel).font(.caption).lineLimit(1)
                    Spacer()
                    if showsControls {
                        Picker("Display", selection: styleBinding) {
                            ForEach(HistogramSurfaceStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 190)
                    } else {
                        Text(styleBinding.wrappedValue.rawValue).font(.caption)
                    }
                }
            }
            Canvas { context, size in
                guard !presentation.result.bins.isEmpty, !presentation.result.groups.isEmpty else { return }
                if presentation.grouping == .column && styleBinding.wrappedValue == .surface && presentation.result.bins.count > 1 && presentation.result.groups.count > 1 {
                    drawSurface(context: &context, size: size)
                } else if presentation.grouping == .column {
                    drawHeatMap(context: &context, size: size)
                } else {
                    drawDistribution(context: &context, size: size)
                }
            }
            .accessibilityLabel(presentation.grouping == .column ? "Joint histogram \(styleBinding.wrappedValue.rawValue)" : "Histogram distribution chart")
            if presentation.grouping == .column {
                Text("\(presentation.normalization(frequency: frequency, table: false)) · color increases from blue to red")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.white)
    }

    private var styleBinding: Binding<HistogramSurfaceStyle> { surfaceStyle ?? $localSurfaceStyle }
    private var xRange: ClosedRange<Double> {
        let lower = presentation.result.bins.first?.lower ?? 0
        return lower...max(lower + Double.leastNormalMagnitude, presentation.result.bins.last?.upper ?? 1)
    }

    private func drawDistribution(context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(x: 60, y: 12, width: max(10, size.width - 82), height: max(10, size.height - 72))
        let grouped = presentation.grouping != .single
        let active = presentation.result.groups.indices.filter { visibleGroups.contains($0) }
        var maximum = 0.0
        for row in presentation.result.bins.indices {
            if grouped {
                for group in active { maximum = max(maximum, presentation.value(row: row, group: group, frequency: frequency, table: false)) }
                if showAggregate { maximum = max(maximum, aggregate(row)) }
            } else {
                maximum = max(maximum, presentation.value(row: row, group: 0, frequency: frequency, table: false))
            }
        }
        if !grouped && showFit && frequency { maximum = max(maximum, presentation.curve.map(\.frequency).max() ?? 0) }
        let ticks = niceTicks(minimum: 0, maximum: max(maximum, 1))
        let top = max(ticks.last ?? 1, maximum)
        let transform = { (x: Double, y: Double) in
            CGPoint(x: plot.minX + (x - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound) * plot.width,
                    y: plot.maxY - y / top * plot.height)
        }
        drawGrid(context: &context, plot: plot, xRange: xRange, yRange: 0...top,
                 xLabel: axisLabel(presentation.primaryLabel, unit: presentation.primaryUnit),
                 yLabel: presentation.normalization(frequency: frequency, table: false))
        var clipped = context
        clipped.clip(to: Path(plot))
        if grouped {
            if showAggregate {
                var path = Path(); path.move(to: transform(xRange.lowerBound, 0))
                for row in presentation.result.bins.indices { path.addLine(to: transform(presentation.result.bins[row].center, aggregate(row))) }
                clipped.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 2.2))
            }
            for group in active {
                var path = Path(); path.move(to: transform(xRange.lowerBound, 0))
                for row in presentation.result.bins.indices {
                    path.addLine(to: transform(presentation.result.bins[row].center,
                                              presentation.value(row: row, group: group, frequency: frequency, table: false)))
                }
                clipped.stroke(path, with: .color(Self.groupColor(group)), lineWidth: 1.5)
            }
        } else {
            for row in presentation.result.bins.indices {
                let bin = presentation.result.bins[row]
                let lower = transform(bin.lower, 0)
                let upper = transform(bin.upper, presentation.value(row: row, group: 0, frequency: frequency, table: false))
                let rect = CGRect(x: lower.x, y: upper.y, width: max(0, upper.x - lower.x), height: max(0, lower.y - upper.y))
                clipped.fill(Path(rect), with: .color(Color(red: 0.62, green: 0.32, blue: 0.17)))
                clipped.stroke(Path(rect), with: .color(.black), lineWidth: 0.5)
            }
            if showFit && frequency {
                var path = Path()
                for (index, point) in presentation.curve.enumerated() where point.frequency.isFinite {
                    if index == 0 { path.move(to: transform(point.x, point.frequency)) }
                    else { path.addLine(to: transform(point.x, point.frequency)) }
                }
                clipped.stroke(path, with: .color(.black), lineWidth: 2)
            }
        }
    }

    private func aggregate(_ row: Int) -> Double {
        let count = Double(presentation.result.counts[row].reduce(0, +))
        return frequency && presentation.result.includedCount > 0
            ? count * 100 / Double(presentation.result.includedCount) : count
    }

    private func drawHeatMap(context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(x: 60, y: 12, width: max(10, size.width - 82), height: max(10, size.height - 72))
        let groups = presentation.result.groups
        let lower = groups.first?.lower ?? 0
        let upper = max(lower + Double.leastNormalMagnitude, groups.last?.upper ?? Double(groups.count))
        let yRange = lower...upper
        let maximum = matrixMaximum
        var clipped = context; clipped.clip(to: Path(plot))
        for row in presentation.result.bins.indices {
            let bin = presentation.result.bins[row]
            let x0 = plot.minX + (bin.lower - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound) * plot.width
            let x1 = plot.minX + (bin.upper - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound) * plot.width
            for group in groups.indices {
                let y0 = groups[group].lower ?? Double(group)
                let y1 = groups[group].upper ?? Double(group + 1)
                let top = plot.maxY - (y1 - lower) / (upper - lower) * plot.height
                let bottom = plot.maxY - (y0 - lower) / (upper - lower) * plot.height
                let value = presentation.value(row: row, group: group, frequency: frequency, table: false)
                clipped.fill(Path(CGRect(x: x0, y: top, width: max(0.2, x1 - x0), height: max(0.2, bottom - top))),
                             with: .color(intensityColor(value / maximum)))
            }
        }
        drawGrid(context: &context, plot: plot, xRange: xRange, yRange: yRange,
                 xLabel: axisLabel(presentation.primaryLabel, unit: presentation.primaryUnit),
                 yLabel: axisLabel(presentation.secondaryLabel, unit: presentation.secondaryUnit), grid: false)
    }

    /// An explicit local isometric projection of the counted joint matrix. The
    /// native surface topology is established; its exact camera is not recovered.
    private func drawSurface(context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(x: 65, y: 18, width: max(10, size.width - 100), height: max(10, size.height - 90))
        let maximum = matrixMaximum
        let groupCount = presentation.result.groups.count
        func point(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            CGPoint(x: plot.minX + x * plot.width * 0.70 + y * plot.width * 0.27,
                    y: plot.maxY - y * plot.height * 0.28 - z * plot.height * 0.65)
        }
        var base = Path()
        base.move(to: point(0, 0, 0)); base.addLine(to: point(1, 0, 0))
        base.addLine(to: point(1, 1, 0)); base.addLine(to: point(0, 1, 0)); base.closeSubpath()
        context.fill(base, with: .color(Color(white: 0.97)))
        context.stroke(base, with: .color(.gray), lineWidth: 0.7)
        // Draw far groups first. Bin heights are actual joint frequencies/counts.
        for group in presentation.result.groups.indices.reversed() {
            for row in presentation.result.bins.indices {
                let value = presentation.value(row: row, group: group, frequency: frequency, table: false)
                let bin = presentation.result.bins[row]
                let x0 = (bin.lower - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                let x1 = (bin.upper - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
                let groupLower = presentation.result.groups.first?.lower ?? 0
                let groupUpper = presentation.result.groups.last?.upper ?? Double(groupCount)
                let groupSpan = max(groupUpper - groupLower, Double.leastNormalMagnitude)
                let y0 = ((presentation.result.groups[group].lower ?? Double(group)) - groupLower) / groupSpan
                let y1 = ((presentation.result.groups[group].upper ?? Double(group + 1)) - groupLower) / groupSpan
                let z = value / maximum
                var patch = Path(); patch.move(to: point(x0, y0, z)); patch.addLine(to: point(x1, y0, z))
                patch.addLine(to: point(x1, y1, z)); patch.addLine(to: point(x0, y1, z)); patch.closeSubpath()
                context.fill(patch, with: .color(intensityColor(z)))
                context.stroke(patch, with: .color(.black.opacity(0.22)), lineWidth: 0.35)
            }
        }
        var zAxis = Path(); zAxis.move(to: point(0, 0, 0)); zAxis.addLine(to: point(0, 0, 1))
        context.stroke(zAxis, with: .color(.black), lineWidth: 1)
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let p = point(0, 0, fraction)
            context.draw(Text(HistogramPresentation.number(maximum * fraction, digits: frequency ? 2 : 0)).font(.system(size: 10)),
                         at: CGPoint(x: p.x - 8, y: p.y), anchor: .trailing)
        }
        let firstX = presentation.result.bins.first!.lower, lastX = presentation.result.bins.last!.upper
        let firstY = presentation.result.groups.first!.lower ?? 0, lastY = presentation.result.groups.last!.upper ?? Double(groupCount)
        context.draw(Text(HistogramPresentation.number(firstX)).font(.system(size: 10)), at: point(0, 0, 0), anchor: .top)
        context.draw(Text(HistogramPresentation.number(lastX)).font(.system(size: 10)), at: point(1, 0, 0), anchor: .top)
        context.draw(Text(HistogramPresentation.number(lastY)).font(.system(size: 10)), at: point(1, 1, 0), anchor: .leading)
        context.draw(Text(HistogramPresentation.number(firstY)).font(.system(size: 10)), at: point(1, 0, 0), anchor: .leading)
        context.draw(Text(axisLabel(presentation.primaryLabel, unit: presentation.primaryUnit)).font(.system(size: 11)),
                     at: CGPoint(x: point(0.5, 0, 0).x, y: plot.maxY + 32), anchor: .center)
        context.draw(Text(axisLabel(presentation.secondaryLabel, unit: presentation.secondaryUnit)).font(.system(size: 11)),
                     at: CGPoint(x: plot.maxX - 12, y: plot.maxY - plot.height * 0.25), anchor: .trailing)
        context.draw(Text(frequency ? "Joint frequency (%)" : "Occurrences").font(.system(size: 11)),
                     at: CGPoint(x: plot.minX, y: 4), anchor: .topLeading)
    }

    private var matrixMaximum: Double {
        max(1e-12, presentation.result.bins.indices.flatMap { row in
            presentation.result.groups.indices.map { presentation.value(row: row, group: $0, frequency: frequency, table: false) }
        }.max() ?? 1)
    }
    private func intensityColor(_ fraction: Double) -> Color {
        guard fraction > 0 else { return .white }
        return Color(hue: (1 - min(1, fraction)) * 0.66, saturation: 0.8, brightness: 0.95)
    }
    private func axisLabel(_ name: String, unit: String) -> String {
        let short = name.count > 48 ? String(name.prefix(45)) + "…" : name
        return unit.isEmpty ? short : "\(short) (\(unit))"
    }
    private func niceTicks(minimum: Double, maximum: Double) -> [Double] {
        let span = max(maximum - minimum, 1e-12)
        let power = pow(10, floor(log10(span / 5)))
        let scaled = span / 5 / power
        let step = (scaled <= 1 ? 1 : scaled <= 2 ? 2 : scaled <= 5 ? 5 : 10) * power
        let lower = floor(minimum / step) * step
        let upper = ceil(maximum / step) * step
        return stride(from: lower, through: upper + step * 1e-6, by: step).map { $0 }
    }
    private func drawGrid(context: inout GraphicsContext, plot: CGRect, xRange: ClosedRange<Double>, yRange: ClosedRange<Double>,
                          xLabel: String, yLabel: String, grid: Bool = true) {
        for x in niceTicks(minimum: xRange.lowerBound, maximum: xRange.upperBound) where xRange.contains(x) {
            let point = CGPoint(x: plot.minX + (x - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound) * plot.width, y: plot.maxY)
            if grid { var path = Path(); path.move(to: point); path.addLine(to: CGPoint(x: point.x, y: plot.minY)); context.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 0.6) }
            context.draw(Text(HistogramPresentation.number(x)).font(.system(size: 10)), at: CGPoint(x: point.x, y: point.y + 7), anchor: .top)
        }
        for y in niceTicks(minimum: yRange.lowerBound, maximum: yRange.upperBound) where yRange.contains(y) {
            let point = CGPoint(x: plot.minX, y: plot.maxY - (y - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound) * plot.height)
            if grid { var path = Path(); path.move(to: point); path.addLine(to: CGPoint(x: plot.maxX, y: point.y)); context.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 0.6) }
            context.draw(Text(HistogramPresentation.number(y)).font(.system(size: 10)), at: CGPoint(x: point.x - 8, y: point.y), anchor: .trailing)
        }
        context.stroke(Path(plot), with: .color(.black), lineWidth: 1)
        context.draw(Text(xLabel).font(.system(size: 11)), at: CGPoint(x: plot.midX, y: plot.maxY + 34), anchor: .top)
        var labelContext = context
        labelContext.translateBy(x: 12, y: plot.midY); labelContext.rotate(by: .degrees(-90))
        labelContext.draw(Text(yLabel).font(.system(size: 11)), at: .zero, anchor: .center)
    }
}
