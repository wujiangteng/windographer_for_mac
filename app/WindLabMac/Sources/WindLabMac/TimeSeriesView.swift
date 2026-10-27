import AppKit
import SwiftUI
import WindogCore

struct TimeSeriesView: View {
    let data: TimeSeriesData
    let fileURL: URL?
    var sourceData: WindExportDataSet? = nil
    var sourceRevision: UUID? = nil
    @State private var displayMode = "Measured Data"
    @State private var visibleChannels: Set<String> = []
    @State private var loadedSeries: [String: NamedSeries] = [:]
    @State private var loadingChannels: Set<String> = []
    @State private var loadError: String?
    @State private var loadGeneration = UUID()
    @State private var loadTasks: [String: Task<Void, Never>] = [:]

    private let displayModes = ["Measured Data", "Daily Means", "Monthly Means", "Annual Means"]

    var body: some View {
        VStack(spacing: 0) {
            displayControls

            HStack(spacing: 0) {
                TimeSeriesChart(
                    series: visibleSeries,
                    channels: data.channels,
                    monthLabels: data.monthLabels,
                    startDate: data.startDate,
                    endDate: data.endDate,
                    mode: parserMode
                )
                .padding(.leading, 10)
                .padding(.bottom, 10)

                TimeSeriesChannelList(
                    channels: data.channels,
                    visibleChannels: $visibleChannels,
                    loadingChannels: loadingChannels,
                    toggleChannel: setChannel(_:visible:)
                )
                .frame(width: 285)
            }
        }
        .onAppear {
            reloadSeries(resetSelection: true)
        }
        .onChange(of: data.channels) { _, _ in
            reloadSeries(resetSelection: true)
        }
        .onChange(of: fileURL) { _, _ in
            reloadSeries(resetSelection: true)
        }
        .onChange(of: sourceRevision) { _, _ in
            reloadSeries(resetSelection: false)
        }
        .onChange(of: displayMode) { _, _ in
            reloadSeries(resetSelection: false)
        }
        .onDisappear {
            cancelLoads()
        }
    }

    private var displayControls: some View {
        HStack(spacing: 18) {
            Text("Display")
                .font(.system(size: 13))

            ForEach(displayModes, id: \.self) { mode in
                Button {
                    displayMode = mode
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: displayMode == mode ? "smallcircle.filled.circle" : "circle")
                            .font(.system(size: 11))
                        Text(mode)
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.plain)
            }

            if let loadError {
                Text(loadError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer()
            Text(modeNote)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("Uses stored values. Quality-flag intervals and derived-only columns are not evaluated. Direction means use the configured or inferred speed association.")
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Color(.windowBackgroundColor))
    }

    private var modeNote: String {
        switch parserMode {
        case "daily": "Recovery ≥75% · flags not filtered"
        case "monthly": "Recovery ≥80% · flags not filtered"
        case "annual": "Recovery ≥90% · flags not filtered"
        default: "Stored values · flags not filtered"
        }
    }

    private var visibleSeries: [NamedSeries] {
        data.channels.filter { visibleChannels.contains($0.id) }.compactMap { loadedSeries[seriesKey($0.id)] }
    }

    private var parserMode: String {
        switch displayMode {
        case "Daily Means": "daily"
        case "Monthly Means": "monthly"
        case "Annual Means": "annual"
        default: "measured"
        }
    }

    private func setChannel(_ id: String, visible: Bool) {
        if visible {
            visibleChannels.insert(id)
            loadSeriesIfNeeded(id)
        } else {
            visibleChannels.remove(id)
        }
    }

    private func cancelLoads() {
        loadGeneration = UUID()
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
        loadingChannels.removeAll()
    }

    private func reloadSeries(resetSelection: Bool) {
        cancelLoads()
        loadedSeries.removeAll()
        loadError = nil
        let available = Set(data.channels.map(\.id))
        if resetSelection {
            visibleChannels = Set(data.channels.filter(\.defaultVisible).map(\.id))
        } else {
            visibleChannels.formIntersection(available)
        }
        data.channels.filter { visibleChannels.contains($0.id) }.forEach { loadSeriesIfNeeded($0.id) }
    }

    private func loadSeriesIfNeeded(_ id: String) {
        let key = seriesKey(id)
        guard loadedSeries[key] == nil, !loadingChannels.contains(id),
              let channel = data.channels.first(where: { $0.id == id }),
              sourceData != nil || fileURL != nil else { return }
        let mode = parserMode
        let generation = loadGeneration
        let dataset = sourceData
        let url = fileURL
        loadingChannels.insert(id)
        loadError = nil

        loadTasks[id] = Task.detached {
            do {
                let decoded: DecodedSeries
                if let dataset {
                    decoded = try NativeTimeSeriesAnalysis.series(dataset: dataset, channelID: id, mode: mode)
                } else if let url {
                    decoded = try WindogParser.parseTimeSeries(fileURL: url, channelID: id, mode: mode)
                } else {
                    return
                }
                guard !Task.isCancelled else { return }
                let series = NamedSeries(name: id, colorName: channel.colorName,
                                         points: decoded.points.map { SeriesPoint(x: $0.x, y: $0.y) })
                await MainActor.run {
                    guard loadGeneration == generation else { return }
                    loadedSeries[key] = series
                    loadingChannels.remove(id)
                    loadTasks.removeValue(forKey: id)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard loadGeneration == generation else { return }
                    loadError = error.localizedDescription
                    loadingChannels.remove(id)
                    loadTasks.removeValue(forKey: id)
                }
            }
        }
    }

    private func seriesKey(_ id: String) -> String {
        "\(parserMode)|\(id)"
    }
}

struct TimeSeriesChannelList: View {
    let channels: [TimeSeriesChannel]
    @Binding var visibleChannels: Set<String>
    let loadingChannels: Set<String>
    let toggleChannel: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                CheckBox(isOn: allWindSpeedSelected)
                Text("All wind speed columns")
                    .font(.system(size: 11))
                Spacer()
            }
            .padding(.bottom, 4)

            HStack(spacing: 5) {
                CheckBox(isOn: allWindDirectionSelected)
                Text("All wind direction columns")
                    .font(.system(size: 11))
                Spacer()
            }
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(channels) { channel in
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(Color.chartColor(channel.colorName))
                                .frame(width: 18, height: 3)
                            CheckBox(isOn: binding(for: channel.id))
                            Text(channel.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if loadingChannels.contains(channel.id) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.55)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 18)
                    }
                }
                .padding(.trailing, 6)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
        .background(Color(red: 0.94, green: 0.94, blue: 0.94))
    }

    private var allWindSpeedSelected: Binding<Bool> {
        Binding {
            let speedChannels = channels.filter { $0.kind == "wind_speed" || $0.kind == "wind_speed_synthesized" }
            return !speedChannels.isEmpty && speedChannels.allSatisfy { visibleChannels.contains($0.id) }
        } set: { newValue in
            channels.filter { $0.kind == "wind_speed" || $0.kind == "wind_speed_synthesized" }.forEach { toggleChannel($0.id, newValue) }
        }
    }

    private var allWindDirectionSelected: Binding<Bool> {
        Binding {
            let directionChannels = channels.filter { $0.kind == "wind_direction" }
            return !directionChannels.isEmpty && directionChannels.allSatisfy { visibleChannels.contains($0.id) }
        } set: { newValue in
            channels.filter { $0.kind == "wind_direction" }.forEach { toggleChannel($0.id, newValue) }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding {
            visibleChannels.contains(id)
        } set: { newValue in
            toggleChannel(id, newValue)
        }
    }
}

struct CheckBox: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "checkmark.square" : "square")
                .font(.system(size: 13))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
    }
}

struct TimeSeriesChart: View {
    let series: [NamedSeries]
    let channels: [TimeSeriesChannel]
    let monthLabels: [TimeAxisLabel]
    let startDate: Date
    let endDate: Date
    let mode: String
    @State private var visibleRange: ClosedRange<Double>?
    @State private var selectionStartX: CGFloat?
    @State private var selectionCurrentX: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let leftInset: CGFloat = 46
            let bottomInset: CGFloat = 36
            let topInset: CGFloat = 8
            let rightInset: CGFloat = rightAxisSeries.isEmpty ? 10 : 58
            let plotSize = CGSize(
                width: max(geometry.size.width - leftInset - rightInset, 10),
                height: max(geometry.size.height - topInset - bottomInset, 10)
            )
            let origin = CGPoint(x: leftInset, y: topInset)
            let fullRange = fullXRange
            let xRange = visibleRange ?? fullRange
            let axisLabels = xAxisLabels(in: xRange)
            let leftTicks = ticks(for: leftYRange)
            let rightTicks = ticks(for: rightYRange)
            let plotMask = Rectangle()
                .frame(width: plotSize.width, height: plotSize.height)
                .position(x: origin.x + plotSize.width / 2, y: origin.y + plotSize.height / 2)

            ZStack(alignment: .topLeading) {
                ChartGrid(
                    xTicks: axisLabels.map(\.x),
                    yTicks: leftTicks,
                    xRange: xRange,
                    yRange: leftYRange,
                    origin: origin,
                    size: plotSize
                )
                seriesLayer(for: leftAxisSeries, range: leftYRange, origin: origin, size: plotSize)
                    .mask(plotMask)
                if !rightAxisSeries.isEmpty {
                    seriesLayer(for: rightAxisSeries, range: rightYRange, origin: origin, size: plotSize)
                        .mask(plotMask)
                }
                Rectangle()
                    .stroke(Color.black, lineWidth: 1)
                    .frame(width: plotSize.width, height: plotSize.height)
                    .position(x: origin.x + plotSize.width / 2, y: origin.y + plotSize.height / 2)

                ForEach(leftTicks, id: \.self) { tick in
                    Text(formatTick(tick))
                        .font(.system(size: 10))
                        .position(x: origin.x - 18, y: yPosition(tick, origin: origin, size: plotSize))
                }

                if !rightAxisSeries.isEmpty {
                    ForEach(rightTicks, id: \.self) { tick in
                        Text(formatTick(tick))
                            .font(.system(size: 10))
                            .position(x: origin.x + plotSize.width + 19, y: yPosition(tick, range: rightYRange, origin: origin, size: plotSize))
                    }
                }

                ForEach(axisLabels) { label in
                    Text(label.label)
                        .font(.system(size: 10))
                        .position(x: xPosition(label.x, xRange: xRange, origin: origin, size: plotSize), y: origin.y + plotSize.height + 17)
                }

                Text(leftAxisLabel)
                    .font(.system(size: 10))
                    .rotationEffect(.degrees(-90))
                    .position(x: 12, y: origin.y + plotSize.height / 2)

                if !rightAxisSeries.isEmpty {
                    Text(rightAxisLabel)
                        .font(.system(size: 10))
                        .rotationEffect(.degrees(-90))
                        .position(x: origin.x + plotSize.width + 42, y: origin.y + plotSize.height / 2)
                }

                if let selectionRect = selectionRect(origin: origin, size: plotSize) {
                    Rectangle()
                        .fill(Color.black.opacity(0.72))
                        .frame(width: selectionRect.width, height: selectionRect.height)
                        .position(x: selectionRect.midX, y: selectionRect.midY)
                }

                ScrollWheelCatcher { deltaY, locationX in
                    zoom(deltaY: deltaY, locationX: locationX, plotWidth: plotSize.width, fullRange: fullRange)
                } onSelectionChanged: { startX, currentX in
                    selectionStartX = min(max(startX, 0), plotSize.width)
                    selectionCurrentX = min(max(currentX, 0), plotSize.width)
                } onDragEnded: {
                    applySelection(plotWidth: plotSize.width, fullRange: fullRange)
                    selectionStartX = nil
                    selectionCurrentX = nil
                }
                .frame(width: plotSize.width, height: plotSize.height)
                .position(x: origin.x + plotSize.width / 2, y: origin.y + plotSize.height / 2)
            }
            .clipped()
            .onChange(of: fullRange) { _, _ in
                visibleRange = fullRange
            }
            .onChange(of: startDate) { _, _ in
                visibleRange = fullRange
            }
            .onAppear {
                visibleRange = fullRange
            }
        }
    }

    private func seriesLayer(for axisSeries: [NamedSeries], range: ClosedRange<Double>,
                             origin: CGPoint, size: CGSize) -> some View {
        let rendered = axisSeries.map { series in
            NamedSeries(name: series.name, colorName: series.colorName,
                        points: TimeSeriesRendering.reduce(points: series.points,
                                                           range: visibleRange ?? fullXRange,
                                                           pixelWidth: max(1, Int(size.width.rounded(.up)))))
        }
        return ZStack(alignment: .topLeading) {
            ChartSeriesLayer(series: rendered, xRange: visibleRange ?? fullXRange,
                             yRange: range, origin: origin, size: size,
                             markerSeriesName: nil, markerMode: .none)
            // A one-period aggregate has no line segment; show its actual point.
            ChartSeriesLayer(series: rendered.filter {
                $0.points.filter { $0.x.isFinite && $0.y.isFinite }.count == 1
            }, xRange: visibleRange ?? fullXRange, yRange: range, origin: origin,
                             size: size, markerSeriesName: nil, markerMode: .all)
        }
    }

    private var channelByID: [String: TimeSeriesChannel] {
        Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
    }

    private var directionSeries: [NamedSeries] {
        series.filter { channelByID[$0.name]?.kind == "wind_direction" }
    }

    private var nonDirectionSeries: [NamedSeries] {
        series.filter { channelByID[$0.name]?.kind != "wind_direction" }
    }

    private var leftAxisSeries: [NamedSeries] {
        directionSeries.isEmpty ? series : directionSeries
    }

    private var rightAxisSeries: [NamedSeries] {
        directionSeries.isEmpty ? [] : nonDirectionSeries
    }

    private var leftYRange: ClosedRange<Double> {
        if !directionSeries.isEmpty {
            return 0...360
        }
        return dynamicYRange(for: leftAxisSeries)
    }

    private var rightYRange: ClosedRange<Double> {
        dynamicYRange(for: rightAxisSeries)
    }

    private var leftAxisLabel: String {
        axisLabel(for: leftAxisSeries, fallback: directionSeries.isEmpty ? "Selected data" : "Wind direction")
    }

    private var rightAxisLabel: String {
        axisLabel(for: rightAxisSeries, fallback: "Selected data")
    }

    private var fullXRange: ClosedRange<Double> {
        let duration = max(endDate.timeIntervalSince(startDate) / 86400, 1.0 / 1440)
        guard mode != "measured" else { return 0...duration }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let component: Calendar.Component = mode == "daily" ? .day : mode == "monthly" ? .month : .year
        guard let first = calendar.dateInterval(of: component, for: startDate),
              let last = calendar.dateInterval(of: component, for: endDate.addingTimeInterval(-0.001)) else {
            return 0...duration
        }
        return first.start.timeIntervalSince(startDate) / 86400...last.end.timeIntervalSince(startDate) / 86400
    }

    private func axisLabel(for axisSeries: [NamedSeries], fallback: String) -> String {
        guard !axisSeries.isEmpty else { return fallback }
        guard axisSeries.count == 1, let item = axisSeries.first, let channel = channelByID[item.name] else {
            if axisSeries.allSatisfy({ channelByID[$0.name]?.kind == "wind_direction" }) {
                return "\(fallback) (°)"
            }
            if axisSeries.allSatisfy({ channelByID[$0.name]?.unit == "m/s" }) {
                return "\(fallback) (m/s)"
            }
            return fallback
        }
        return "\(channel.name) (\(displayUnit(channel.unit)))"
    }

    private func displayUnit(_ unit: String) -> String {
        unit == "deg" ? "°" : unit
    }

    private func dynamicYRange(for axisSeries: [NamedSeries]) -> ClosedRange<Double> {
        let values = axisSeries.flatMap(\.points).map(\.y).filter(\.isFinite)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0...30
        }
        let padding = max((maxValue - minValue) * 0.08, 1)
        // Range padding is a local display choice; negative temperature and
        // vertical-speed observations must remain visible.
        let nonnegative = axisSeries.allSatisfy { item in
            guard let kind = channelByID[item.name]?.kind else { return false }
            return ["wind_speed", "wind_speed_synthesized", "power_density", "pressure", "density", "humidity"].contains(kind)
        }
        let paddedLower = floor((minValue - padding) / 5) * 5
        let lower = nonnegative ? max(0, paddedLower) : paddedLower
        let upper = max(lower + 1, ceil((maxValue + padding) / 5) * 5)
        return lower...upper
    }

    private func ticks(for range: ClosedRange<Double>) -> [Double] {
        let span = max(range.upperBound - range.lowerBound, 1)
        let rawStep = span / 6
        let step: Double
        if rawStep <= 1 {
            step = 1
        } else if rawStep <= 2 {
            step = 2
        } else if rawStep <= 5 {
            step = 5
        } else if rawStep <= 10 {
            step = 10
        } else if rawStep <= 30 {
            step = 30
        } else {
            step = 60
        }
        let start = ceil(range.lowerBound / step) * step
        return stride(from: start, through: range.upperBound, by: step).map { $0 }
    }

    private func xAxisLabels(in range: ClosedRange<Double>) -> [TimeAxisLabel] {
        let span = range.upperBound - range.lowerBound
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone

        if mode == "monthly" || mode == "annual" {
            let component: Calendar.Component = mode == "monthly" ? .month : .year
            let lowerDate = startDate.addingTimeInterval(range.lowerBound * 86400)
            var cursor = calendar.dateInterval(of: component, for: lowerDate)!.start
            var labels: [TimeAxisLabel] = []
            formatter.dateFormat = mode == "annual" ? "yyyy" : "MMM yyyy"
            while cursor <= startDate.addingTimeInterval(range.upperBound * 86400) {
                guard let period = calendar.dateInterval(of: component, for: cursor) else { break }
                let x = period.start.addingTimeInterval(period.duration / 2).timeIntervalSince(startDate) / 86400
                if range.contains(x) { labels.append(TimeAxisLabel(x: x, label: formatter.string(from: cursor))) }
                cursor = period.end
            }
            // Keep labels readable for long records while preserving mean positions.
            let strideCount = max(1, Int(ceil(Double(labels.count) / 12)))
            return labels.enumerated().filter { $0.offset % strideCount == 0 }.map(\.element)
        }

        let stepDays: Double
        if span <= 2 {
            stepDays = 1.0 / 12.0
            formatter.dateFormat = "M/d HH:mm"
        } else if span <= 14 {
            stepDays = 1
            formatter.dateFormat = "M/d"
        } else if span <= 90 {
            stepDays = 7
            formatter.dateFormat = "M/d"
        } else {
            return monthLabels.filter { range.contains($0.x) }
        }

        let start = floor(range.lowerBound / stepDays) * stepDays
        let values = stride(from: start, through: range.upperBound, by: stepDays)
        return values.compactMap { x in
            guard range.contains(x) else {
                return nil
            }
            let date = calendar.date(byAdding: .second, value: Int(x * 86400), to: startDate) ?? startDate
            return TimeAxisLabel(x: x, label: formatter.string(from: date))
        }
    }

    private func zoom(deltaY: Double, locationX: CGFloat, plotWidth: CGFloat, fullRange: ClosedRange<Double>) {
        let current = visibleRange ?? fullRange
        let span = current.upperBound - current.lowerBound
        let factor = exp(-deltaY * 0.003)
        let fullSpan = fullRange.upperBound - fullRange.lowerBound
        let minimumSpan = min(fullSpan, 1.0 / 1440)
        let newSpan = min(max(span * factor, minimumSpan), fullSpan)
        let anchorFraction = min(max(Double(locationX / max(plotWidth, 1)), 0), 1)
        let anchorValue = current.lowerBound + span * anchorFraction
        let lower = anchorValue - newSpan * anchorFraction
        visibleRange = clampedRange(lower: lower, span: newSpan, fullRange: fullRange)
    }

    private func clampedRange(center: Double, span: Double, fullRange: ClosedRange<Double>) -> ClosedRange<Double> {
        let half = span / 2
        var lower = center - half
        var upper = center + half
        if lower < fullRange.lowerBound {
            lower = fullRange.lowerBound
            upper = lower + span
        }
        if upper > fullRange.upperBound {
            upper = fullRange.upperBound
            lower = upper - span
        }
        return max(fullRange.lowerBound, lower)...min(fullRange.upperBound, upper)
    }

    private func clampedRange(lower: Double, span: Double, fullRange: ClosedRange<Double>) -> ClosedRange<Double> {
        var lower = lower
        var upper = lower + span
        if lower < fullRange.lowerBound {
            lower = fullRange.lowerBound
            upper = lower + span
        }
        if upper > fullRange.upperBound {
            upper = fullRange.upperBound
            lower = upper - span
        }
        return max(fullRange.lowerBound, lower)...min(fullRange.upperBound, upper)
    }

    private func selectionRect(origin: CGPoint, size: CGSize) -> CGRect? {
        guard let selectionStartX, let selectionCurrentX else {
            return nil
        }
        let minX = min(selectionStartX, selectionCurrentX)
        let width = abs(selectionCurrentX - selectionStartX)
        guard width > 2 else {
            return nil
        }
        return CGRect(x: origin.x + minX, y: origin.y, width: width, height: size.height)
    }

    private func applySelection(plotWidth: CGFloat, fullRange: ClosedRange<Double>) {
        guard let selectionStartX, let selectionCurrentX else {
            return
        }
        let minX = min(selectionStartX, selectionCurrentX)
        let maxX = max(selectionStartX, selectionCurrentX)
        guard maxX - minX > 8 else {
            return
        }
        let current = visibleRange ?? fullRange
        let span = current.upperBound - current.lowerBound
        let lower = current.lowerBound + Double(minX / max(plotWidth, 1)) * span
        let upper = current.lowerBound + Double(maxX / max(plotWidth, 1)) * span
        visibleRange = max(fullRange.lowerBound, lower)...min(fullRange.upperBound, upper)
    }

    private func xPosition(_ value: Double, xRange: ClosedRange<Double>, origin: CGPoint, size: CGSize) -> CGFloat {
        let fraction = (value - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)
        return origin.x + CGFloat(fraction) * size.width
    }

    private func yPosition(_ value: Double, origin: CGPoint, size: CGSize) -> CGFloat {
        yPosition(value, range: leftYRange, origin: origin, size: size)
    }

    private func yPosition(_ value: Double, range: ClosedRange<Double>, origin: CGPoint, size: CGSize) -> CGFloat {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return origin.y + size.height - CGFloat(fraction) * size.height
    }

    private func formatTick(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (Double, CGFloat) -> Void
    let onSelectionChanged: (CGFloat, CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.onScroll = onScroll
        view.onSelectionChanged = onSelectionChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onSelectionChanged = onSelectionChanged
        nsView.onDragEnded = onDragEnded
    }
}

final class ScrollWheelView: NSView {
    var onScroll: ((Double, CGFloat) -> Void)?
    var onSelectionChanged: ((CGFloat, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStartX: CGFloat?

    override func scrollWheel(with event: NSEvent) {
        let locationX = convert(event.locationInWindow, from: nil).x
        onScroll?(Double(event.scrollingDeltaY), locationX)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else {
            return
        }
        let currentX = convert(event.locationInWindow, from: nil).x
        onSelectionChanged?(dragStartX, currentX)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        onDragEnded?()
    }
}
