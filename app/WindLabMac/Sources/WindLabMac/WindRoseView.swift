import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WindogCore

private struct RoseOptions: Hashable {
    var display = RoseDisplay.occurrences
    var grouping = RoseGrouping.allDirections
    var sectors = 16
    var direction = ""
    var dataIDs: Set<String> = []
    var speed = ""
    var binColumn = ""
    var customWidth = false
    var customStart = false
    var halfFirst = false
    var width = "1"
    var start = "0"
    var dateFilter = false
    var year = "-"
    var month = "-"
    var rangeFilter = false
    var from = Date(timeIntervalSince1970: 0)
    var to = Date(timeIntervalSince1970: 0)
    var columnFilter = false
    var filterColumn = "-"
    var minimumEnabled = true
    var maximumEnabled = true
    var minimum = "0"
    var maximum = "50"
    var flagFilter = true
    var unflagged = true
    var flagIDs: Set<UInt16> = []
}

struct WindRoseView: View {
    let series: [NamedPolarSeries]
    let data: TimeSeriesData
    let fileURL: URL?
    var sourceData: WindExportDataSet? = nil
    var sourceRevision: UUID? = nil
    @State private var options = RoseOptions()
    @State private var result: RoseResult?
    @State private var visibleIDs: Set<String> = []
    @State private var table = false
    @State private var style = RosePlotStyle.line
    @State private var northOffset = 0.0
    @State private var showsGrid = true
    @State private var busy = false
    @State private var error: String?

    private var loadKey: String { "\(options)|\(sourceRevision?.uuidString ?? "")|\(fileURL?.path ?? "")" }
    private var directionColumns: [TimeSeriesChannel] {
        data.channels.filter { channel in
            guard channel.kind == "wind_direction" else { return false }
            return sourceData?.columns.first { $0.id == channel.id }?.subtype == "Mean" || WindColumnMetadata.subtype(in: channel.name) == "Mean"
        }
    }
    private var speedColumns: [TimeSeriesChannel] {
        data.channels.filter { $0.kind == "wind_speed" && $0.unit == "m/s" && WindColumnMetadata.subtype(in: $0.name) == "Mean" }
    }
    private var flagsAvailable: Bool {
        sourceData?.flags != nil && sourceData?.columns.allSatisfy { $0.flagIntervals != nil } == true
    }
    private var groupings: [RoseGrouping] {
        options.display == .totalEnergy ? [.direction, .month] : options.display == .occurrences || options.display == .frequency
            ? RoseGrouping.allCases : [.direction, .month, .hour, .bin]
    }
    private var title: String { Self.label(options.display) + " vs. " + Self.label(options.grouping) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { controls.padding(12) }.frame(width: 360)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Copy table") { copyTable() }.disabled(result == nil)
                    Button("Export CSV…") { saveCSV() }.disabled(result == nil)
                    Button("Save graph…") { saveGraph() }.disabled(result == nil)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let result {
                    if table {
                        WindRoseResultTable(result: result, display: options.display)
                    } else {
                        HStack(alignment: .top) {
                            WindRoseVisualization(result: result, display: options.display, visibleIDs: visibleIDs,
                                style: style, northOffset: northOffset, showsGrid: showsGrid).background(.white)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(Array(result.series.enumerated()), id: \.element.id) { index, item in
                                        Toggle(item.label, isOn: Binding(get: { visibleIDs.contains(item.id) }, set: {
                                            if $0 { visibleIDs.insert(item.id) } else { visibleIDs.remove(item.id) }
                                        })).help(item.label).foregroundStyle(WindRoseVisualization.seriesColor(item, index: index))
                                    }
                                }.toggleStyle(.checkbox)
                            }.frame(width: 190)
                        }
                    }
                    Text("Valid source rows: \(result.overallValidCount.formatted()) · Calm rows: \(result.calmCount.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(result.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                } else {
                    ContentUnavailableView("No wind rose", systemImage: "wind", description: Text(error ?? "Choose a direction column."))
                }
            }.padding(12)
        }
        .background(Color(.windowBackgroundColor))
        .font(.system(size: 12))
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .onAppear { reset() }
        .onChange(of: data.channels) { _, _ in reset() }
        .onChange(of: fileURL) { _, _ in reset() }
        .onChange(of: options.display) { _, _ in
            if !groupings.contains(options.grouping) { options.grouping = .direction }
            if options.display == .totalEnergy { options.dataIDs = options.dataIDs.intersection(Set(speedColumns.map(\.id))) }
            if options.dataIDs.isEmpty, let id = speedColumns.first?.id { options.dataIDs = [id] }
            if [.mean, .minimum, .maximum, .standardDeviation, .scatter].contains(options.display),
               let unit = data.channels.first(where: { options.dataIDs.contains($0.id) })?.unit {
                options.dataIDs = options.dataIDs.intersection(Set(data.channels.filter { $0.unit == unit }.map(\.id)))
            }
        }
        .task(id: loadKey) { await calculate() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Display", selection: $options.display) { ForEach(RoseDisplay.allCases, id: \.self) { Text(Self.label($0)).tag($0) } }
            Picker("versus", selection: $options.grouping) { ForEach(groupings, id: \.self) { Text(Self.label($0)).tag($0) } }
            HStack {
                Picker("Sectors", selection: $options.sectors) {
                    ForEach([4,8,12,16,18,24,36,48,72,120,180,360], id: \.self) { Text(String($0)).tag($0) }
                }
                Picker("Format", selection: $table) { Text("Chart").tag(false); Text("Table").tag(true) }.pickerStyle(.segmented)
            }
            DisclosureGroup("Style") {
                Picker("Plot", selection: $style) {
                    Text("Line").tag(RosePlotStyle.line); Text("Filled").tag(RosePlotStyle.filled); Text("Bars").tag(RosePlotStyle.bars)
                }.disabled(options.display == .scatter)
                Toggle("Show radial grid", isOn: $showsGrid)
                HStack { Text("Rotate view"); Slider(value: $northOffset, in: 0...360); Text("\(Int(northOffset))°") }
            }
            Divider()
            Picker("Direction sensor", selection: $options.direction) {
                ForEach(directionColumns) { Text($0.name).tag($0.id) }
            }.disabled(options.grouping == .allDirections)
            if options.grouping != .allDirections {
                HStack { Text("Data columns"); Spacer(); Button("Clear All") { options.dataIDs.removeAll() } }
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(options.display == .totalEnergy ? speedColumns : data.channels) { channel in
                            Toggle(channel.name, isOn: Binding(get: { options.dataIDs.contains(channel.id) }, set: {
                                if $0 { options.dataIDs.insert(channel.id) } else { options.dataIDs.remove(channel.id) }
                            })).help(channel.name).disabled(!allowsUnit(channel))
                        }
                    }.toggleStyle(.checkbox)
                }.frame(height: 115)
            }
            Picker("Speed sensor", selection: $options.speed) {
                Text("<Automatic association>").tag("")
                ForEach(speedColumns) { Text($0.name).tag($0.id) }
            }
            if options.grouping == .bin {
                Picker("Bin column", selection: $options.binColumn) { ForEach(data.channels) { Text($0.name).tag($0.id) } }
                HistogramBinControls(unit: data.channels.first { $0.id == options.binColumn }?.unit ?? "",
                    customWidth: $options.customWidth, customStart: $options.customStart, halfFirst: $options.halfFirst,
                    width: $options.width, start: $options.start)
            }
            Divider()
            Text("Filter by").fontWeight(.medium)
            if flagsAvailable, let flags = sourceData?.flags {
                Toggle("Flag", isOn: $options.flagFilter)
                VStack(alignment: .leading) {
                    Toggle("<Unflagged data>", isOn: $options.unflagged)
                    ForEach(flags, id: \.id) { flag in
                        Toggle(flag.name, isOn: Binding(get: { options.flagIDs.contains(flag.id) }, set: {
                            if $0 { options.flagIDs.insert(flag.id) } else { options.flagIDs.remove(flag.id) }
                        }))
                    }
                }.padding(.leading, 12).disabled(!options.flagFilter)
            } else { Text("Flag intervals unavailable; stored values are used.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Date", isOn: $options.dateFilter)
            HStack {
                Picker("Year", selection: $options.year) {
                    Text("<All>").tag("-"); ForEach(data.years, id: \.self) { Text(String($0)).tag(String($0)) }
                }
                Picker("Month", selection: $options.month) {
                    Text("<All>").tag("-"); ForEach(1...12, id: \.self) { Text(String($0)).tag(String($0)) }
                }.disabled(options.grouping == .month)
            }.disabled(!options.dateFilter)
            Toggle("Date range", isOn: $options.rangeFilter)
            HStack {
                DatePicker("From", selection: $options.from, displayedComponents: .date).labelsHidden()
                Text("to"); DatePicker("To", selection: $options.to, displayedComponents: .date).labelsHidden()
            }.disabled(!options.rangeFilter)
            Toggle("Data column", isOn: $options.columnFilter)
            Picker("", selection: $options.filterColumn) {
                Text("<All>").tag("-"); ForEach(data.channels) { Text($0.name).tag($0.id) }
            }.labelsHidden().disabled(!options.columnFilter)
            HStack {
                Toggle("Min", isOn: $options.minimumEnabled)
                TextField("", text: $options.minimum).frame(width: 55).disabled(!options.minimumEnabled)
                Toggle("Max", isOn: $options.maximumEnabled)
                TextField("", text: $options.maximum).frame(width: 55).disabled(!options.maximumEnabled)
            }.disabled(!options.columnFilter).textFieldStyle(.roundedBorder)
        }.toggleStyle(.checkbox)
    }

    private func allowsUnit(_ channel: TimeSeriesChannel) -> Bool {
        guard [.mean, .minimum, .maximum, .standardDeviation, .scatter].contains(options.display), !options.dataIDs.contains(channel.id) else { return true }
        let units = Set(data.channels.filter { options.dataIDs.contains($0.id) }.map(\.unit))
        return units.isEmpty || units.contains(channel.unit)
    }

    private func reset() {
        options.direction = directionColumns.first?.id ?? ""
        options.dataIDs = Set(speedColumns.first.map { [$0.id] } ?? [])
        options.binColumn = speedColumns.first?.id ?? data.channels.first?.id ?? ""
        options.from = data.startDate; options.to = data.endDate.addingTimeInterval(-1)
        options.flagIDs = Set(sourceData?.flags?.filter { $0.name.localizedCaseInsensitiveContains("synth") || $0.name.contains("合成") }.map(\.id) ?? [])
    }

    private func calculate() async {
        guard !options.direction.isEmpty else { return }
        let options = options; let dataset = sourceData; let url = fileURL; let canFilterFlags = flagsAvailable
        busy = true; error = nil
        do {
            let next = try await Task.detached {
                let source: WindExportDataSet
                if let dataset { source = dataset }
                else if let url { source = try WindogParser.exportDataSet(fileURL: url) }
                else { throw WindogError.invalid("No file") }
                let filtered = NativeFlagFiltering.applying(to: source, enabled: options.flagFilter && canFilterFlags,
                                                           includeUnflagged: options.unflagged, flagIDs: options.flagIDs)
                func number(_ text: String) throws -> Double {
                    guard let value = Double(text), value.isFinite else { throw WindogError.invalid("Invalid numeric setting: \(text)") }
                    return value
                }
                var selection = HistogramSelection()
                if options.dateFilter { selection.year = Int(options.year); selection.month = Int(options.month) }
                if options.rangeFilter { selection.startDate = Self.day(options.from); selection.endDate = Self.day(options.to).addingTimeInterval(86400) }
                if options.columnFilter, options.filterColumn != "-" {
                    selection.columnID = options.filterColumn
                    selection.minimum = options.minimumEnabled ? try number(options.minimum) : nil
                    selection.maximum = options.maximumEnabled ? try number(options.maximum) : nil
                }
                let ids = source.columns.filter { options.dataIDs.contains($0.id) }.map(\.id)
                let request = RoseRequest(directionID: options.direction, dataIDs: ids,
                    grouping: options.grouping, display: options.display, sectors: options.sectors,
                    binID: options.binColumn.isEmpty ? nil : options.binColumn, speedID: options.speed.isEmpty ? nil : options.speed,
                    bins: HistogramBinSettings(width: options.customWidth ? try number(options.width) : nil,
                                               start: options.customStart ? try number(options.start) : nil, halfFirst: options.halfFirst),
                    selection: selection)
                return try WindRoseAnalysis.analyze(filtered, request: request)
            }.value
            guard !Task.isCancelled else { return }
            let old = Set(result?.series.map(\.id) ?? [])
            let available = Set(next.series.map(\.id))
            visibleIDs = old == available ? visibleIDs : available
            result = next; busy = false
        } catch {
            guard !Task.isCancelled else { return }
            result = nil; self.error = error.localizedDescription; busy = false
        }
    }

    nonisolated private static func day(_ value: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.startOfDay(for: value)
    }
    nonisolated private static func label(_ value: RoseDisplay) -> String {
        switch value {
        case .standardDeviation: "Standard deviation"
        case .totalEnergy: "Total energy share"
        case .scatter: "Scatter plot"
        default: value.rawValue.capitalized
        }
    }
    nonisolated private static func label(_ value: RoseGrouping) -> String {
        switch value {
        case .allDirections: "All direction sensors"
        case .direction: "Direction"
        case .month: "Direction and month"
        case .hour: "Direction and two-hour period"
        case .bin: "Direction and bin"
        }
    }
    private func copyTable() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(NativeRoseTable.text(result, display: options.display), forType: .string)
    }
    private func saveCSV() {
        guard let result else { return }
        let text = "\u{FEFF}" + NativeRoseTable.text(result, display: options.display, delimiter: ",")
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "wind-rose.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func saveGraph() {
        guard let result else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "wind-rose.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let renderer = ImageRenderer(content: WindRoseVisualization(result: result, display: options.display, visibleIDs: visibleIDs,
                style: style, northOffset: northOffset, showsGrid: showsGrid).frame(width: 1000, height: 1000).background(.white))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return }
            do { try png.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
        }
    }
}

enum NativeRoseTable {
    static func text(_ result: RoseResult, display: RoseDisplay, delimiter: String = "\t") -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows: [[String]] = []
        if display == .scatter {
            rows.append(["Data column", "Direction (deg)", "Value", "Unit"])
            for series in result.series {
                for point in series.scatterPoints {
                    rows.append([series.label, HistogramPresentation.number(point.direction), HistogramPresentation.number(point.value), series.unit])
                }
            }
        } else {
            rows.append(["Sector center (deg)"] + result.series.map { $0.label + " [" + $0.unit + "]" })
            for index in result.sectorCenters.indices {
                rows.append([HistogramPresentation.number(result.sectorCenters[index])] + result.series.map {
                    $0.sectorValues[index].map { HistogramPresentation.number($0) } ?? "n/a"
                })
            }
        }
        return rows.map { $0.map(quote).joined(separator: delimiter) }.joined(separator: "\r\n") + "\r\n"
    }
}
