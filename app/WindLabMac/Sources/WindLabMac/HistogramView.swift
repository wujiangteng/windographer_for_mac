import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WindogCore

struct HistogramBar: Identifiable {
    let id = UUID()
    let x: Double
    let y: Double
    let width: Double
}

private struct HistogramOptions: Hashable {
    var primary = ""
    var secondary = ""
    var grouping = "single"
    var customWidth = false
    var customStart = false
    var halfFirst = false
    var width = "0.5"
    var start = "0"
    var secondaryCustomWidth = false
    var secondaryCustomStart = false
    var secondaryHalfFirst = false
    var secondaryWidth = "1"
    var secondaryStart = "0"
    var dateFilter = false
    var year = "-"
    var month = "-"
    var rangeFilter = false
    var startDate = Date(timeIntervalSince1970: 0)
    var endDate = Date(timeIntervalSince1970: 0)
    var columnFilter = false
    var filterColumn = "-"
    var minimumEnabled = true
    var maximumEnabled = true
    var minimum = "0"
    var maximum = "50"
    var flagFilter = true
    var includeUnflagged = true
    var flagIDs: Set<UInt16> = []
}

struct HistogramView: View {
    let data: TimeSeriesData
    let fileURL: URL?
    var sourceData: WindExportDataSet? = nil
    var sourceRevision: UUID? = nil
    @State private var options = HistogramOptions()
    @State private var frequency = true
    @State private var table = false
    @State private var showFit = true
    @State private var surfaceStyle: HistogramSurfaceStyle = .surface
    @State private var presentation: HistogramPresentation?
    @State private var visibleGroups: Set<Int> = []
    @State private var showAggregate = true
    @State private var loading = false
    @State private var error: String?

    private var loadKey: String { "\(options)|\(sourceRevision?.uuidString ?? "")|\(fileURL?.path ?? "")" }
    private var primaryUnit: String { data.channels.first { $0.id == options.primary }?.unit ?? "" }
    private var secondaryUnit: String { data.channels.first { $0.id == options.secondary }?.unit ?? "" }
    private var flagsAvailable: Bool {
        guard let sourceData, let primary = sourceData.columns.first(where: { $0.id == options.primary }), primary.flagIntervals != nil else { return false }
        return options.grouping != "column" || sourceData.columns.first(where: { $0.id == options.secondary })?.flagIntervals != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { controls.padding(12) }.frame(width: 360)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(presentation?.normalization(frequency: frequency, table: table) ?? "Histogram")
                        .font(.headline)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button("Copy table") { copyTable() }.disabled(presentation == nil)
                    Button("Export CSV…") { saveTable() }.disabled(presentation == nil)
                    Button("Save graph…") { saveGraph() }.disabled(presentation == nil)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let presentation {
                    Text(presentation.primaryLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if table {
                        HistogramResultTable(presentation: presentation, frequency: frequency)
                    } else {
                        HistogramVisualization(presentation: presentation, frequency: frequency,
                                               showFit: showFit, visibleGroups: visibleGroups, showAggregate: showAggregate, surfaceStyle: $surfaceStyle)
                            .background(.white)
                        legend(presentation)
                    }
                    Text("Valid records: \(presentation.result.sampleCount.formatted()) · In displayed bins: \(presentation.result.includedCount.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("No histogram", systemImage: "chart.bar", description: Text(error ?? "Select a data column."))
                }
            }.padding(12)
        }
        .font(.system(size: 12))
        .background(Color(.windowBackgroundColor))
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .onAppear { reset() }
        .onChange(of: data.channels) { _, _ in reset() }
        .onChange(of: fileURL) { _, _ in reset() }
        .task(id: loadKey) { await calculate() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("Display", selection: $frequency) { Text("frequency").tag(true); Text("occurrences").tag(false) }
                .pickerStyle(.radioGroup).horizontalRadioGroupLayout()
            Picker("Format", selection: $table) { Text("Chart").tag(false); Text("Table").tag(true) }.pickerStyle(.segmented)
            Picker("versus", selection: $options.grouping) {
                Text("one data column").tag("single")
                Text("data column and month").tag("month")
                Text("data column and hour of day").tag("hour")
                Text("two data columns").tag("column")
            }.pickerStyle(.radioGroup)
            Divider()
            columnPicker("Primary bins", selection: $options.primary)
            HistogramBinControls(unit: primaryUnit, customWidth: $options.customWidth, customStart: $options.customStart,
                                 halfFirst: $options.halfFirst, width: $options.width, start: $options.start)
            if options.grouping == "column" {
                columnPicker("Secondary bins", selection: $options.secondary)
                HistogramBinControls(unit: secondaryUnit, customWidth: $options.secondaryCustomWidth,
                                     customStart: $options.secondaryCustomStart, halfFirst: $options.secondaryHalfFirst,
                                     width: $options.secondaryWidth, start: $options.secondaryStart)
            }
            if options.grouping == "single" {
                Toggle("Show Weibull fit (mean wind speed)", isOn: $showFit)
                    .disabled(!frequency || presentation?.fitLabel == nil)
            }
            Divider()
            Text("Filter by").fontWeight(.medium)
            if flagsAvailable, let flags = sourceData?.flags {
                Toggle("Flag", isOn: $options.flagFilter)
                VStack(alignment: .leading) {
                    Toggle("<Unflagged data>", isOn: $options.includeUnflagged)
                    ForEach(flags, id: \.id) { flag in
                        Toggle(flag.name, isOn: Binding(get: { options.flagIDs.contains(flag.id) }, set: {
                            if $0 { options.flagIDs.insert(flag.id) } else { options.flagIDs.remove(flag.id) }
                        }))
                    }
                }.padding(.leading, 12).disabled(!options.flagFilter)
            } else {
                Text("Flag intervals unavailable for this selection; stored values are used.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Date", isOn: $options.dateFilter)
            HStack {
                Picker("Year", selection: $options.year) {
                    Text("<All>").tag("-"); ForEach(data.years, id: \.self) { Text(String($0)).tag(String($0)) }
                }
                Picker("Month", selection: $options.month) {
                    Text("<All>").tag("-"); ForEach(1...12, id: \.self) { Text(String($0)).tag(String($0)) }
                }.disabled(options.grouping == "month")
            }.disabled(!options.dateFilter)
            Toggle("Date range", isOn: $options.rangeFilter)
            HStack {
                DatePicker("From", selection: $options.startDate, displayedComponents: .date).labelsHidden()
                Text("to")
                DatePicker("To", selection: $options.endDate, displayedComponents: .date).labelsHidden()
            }.disabled(!options.rangeFilter)
            Toggle("Data column", isOn: $options.columnFilter)
            columnPicker("", selection: $options.filterColumn, includesAll: true).disabled(!options.columnFilter)
            HStack {
                Toggle("Min", isOn: $options.minimumEnabled)
                TextField("", text: $options.minimum).frame(width: 58).disabled(!options.minimumEnabled)
                Toggle("Max", isOn: $options.maximumEnabled)
                TextField("", text: $options.maximum).frame(width: 58).disabled(!options.maximumEnabled)
            }.disabled(!options.columnFilter).textFieldStyle(.roundedBorder)
        }.toggleStyle(.checkbox)
    }

    private func columnPicker(_ title: String, selection: Binding<String>, includesAll: Bool = false) -> some View {
        Picker(title, selection: selection) {
            if includesAll { Text("<All>").tag("-") }
            ForEach(data.channels) { Text($0.name).tag($0.id) }
        }.pickerStyle(.menu)
    }

    @ViewBuilder private func legend(_ presentation: HistogramPresentation) -> some View {
        if presentation.grouping == .month || presentation.grouping == .hour {
            ScrollView(.horizontal) {
                HStack {
                    Toggle("All data", isOn: $showAggregate)
                    ForEach(presentation.result.groups.indices, id: \.self) { index in
                        Toggle(presentation.result.groups[index].label, isOn: Binding(get: { visibleGroups.contains(index) }, set: {
                            if $0 { visibleGroups.insert(index) } else { visibleGroups.remove(index) }
                        })).foregroundStyle(HistogramVisualization.groupColor(index))
                    }
                }.toggleStyle(.checkbox)
            }.frame(height: 28)
        } else if showFit, frequency, let fit = presentation.fitLabel {
            Text("Actual data · \(fit)").font(.caption)
        }
    }

    private func reset() {
        options.primary = data.channels.first(where: \.defaultVisible)?.id ?? data.channels.first?.id ?? ""
        options.secondary = data.channels.first { $0.id != options.primary }?.id ?? options.primary
        options.startDate = data.startDate
        options.endDate = data.endDate.addingTimeInterval(-1)
        options.flagIDs = Set(sourceData?.flags?.filter { $0.name.localizedCaseInsensitiveContains("synth") || $0.name.contains("合成") }.map(\.id) ?? [])
    }

    private func calculate() async {
        guard !options.primary.isEmpty else { return }
        let options = options
        let dataset = sourceData
        let url = fileURL
        let canFilterFlags = flagsAvailable
        loading = true
        error = nil
        do {
            let result = try await Task.detached {
                var source: WindExportDataSet
                if let dataset { source = dataset }
                else if let url { source = try WindogParser.exportDataSet(fileURL: url) }
                else { throw WindogError.invalid("No data file") }
                source = NativeFlagFiltering.applying(to: source, enabled: options.flagFilter && canFilterFlags,
                    includeUnflagged: options.includeUnflagged, flagIDs: options.flagIDs,
                    targetIDs: Set([options.primary, options.grouping == "column" ? options.secondary : "", options.columnFilter ? options.filterColumn : ""]))
                func number(_ text: String) throws -> Double {
                    guard let number = Double(text), number.isFinite else { throw WindogError.invalid("Invalid numeric setting: \(text)") }
                    return number
                }
                var selection = HistogramSelection()
                if options.dateFilter { selection.year = Int(options.year); selection.month = Int(options.month) }
                if options.rangeFilter {
                    selection.startDate = Self.day(options.startDate)
                    selection.endDate = Self.day(options.endDate).addingTimeInterval(86400)
                }
                if options.columnFilter, options.filterColumn != "-" {
                    selection.columnID = options.filterColumn
                    selection.minimum = options.minimumEnabled ? try number(options.minimum) : nil
                    selection.maximum = options.maximumEnabled ? try number(options.maximum) : nil
                }
                let grouping: HistogramGrouping = switch options.grouping {
                case "month": .month
                case "hour": .hour
                case "column": .column
                default: .single
                }
                if options.flagFilter && canFilterFlags {
                    let ids = grouping == .column ? [options.primary, options.secondary] : [options.primary]
                    var allowed: Set<Int>?
                    for id in ids {
                        guard let column = source.columns.first(where: { $0.id == id }), let intervals = column.flagIntervals else { continue }
                        let indices = WindogFlagSelection.includedIndices(intervals: intervals, rowCount: column.values.count,
                                                                         includeUnflagged: options.includeUnflagged, flagIDs: options.flagIDs)
                        allowed = allowed.map { $0.intersection(indices) } ?? indices
                    }
                    selection.includedIndices = allowed
                }
                let request = HistogramRequest(primaryID: options.primary, grouping: grouping, secondaryID: options.secondary,
                    primaryBins: HistogramBinSettings(width: options.customWidth ? try number(options.width) : nil,
                                                      start: options.customStart ? try number(options.start) : nil, halfFirst: options.halfFirst),
                    secondaryBins: HistogramBinSettings(width: options.secondaryCustomWidth ? try number(options.secondaryWidth) : nil,
                                                        start: options.secondaryCustomStart ? try number(options.secondaryStart) : nil, halfFirst: options.secondaryHalfFirst),
                    selection: selection)
                return try NativeHistogramAnalysis.build(dataset: source, request: request)
            }.value
            guard !Task.isCancelled else { return }
            if presentation?.grouping != result.grouping { visibleGroups = Set(result.result.groups.indices) }
            presentation = result
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            presentation = nil
            self.error = error.localizedDescription
            loading = false
        }
    }

    nonisolated private static func day(_ value: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.startOfDay(for: value)
    }

    private func copyTable() {
        guard let presentation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(presentation.tableText(frequency: frequency), forType: .string)
    }
    private func saveTable() {
        guard let presentation else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "histogram.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try ("\u{FEFF}" + presentation.tableText(frequency: frequency, delimiter: ",")).write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = error.localizedDescription }
        }
    }
    @MainActor private func saveGraph() {
        guard let presentation else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "histogram.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let renderer = ImageRenderer(content: HistogramVisualization(presentation: presentation, frequency: frequency,
                showFit: showFit, visibleGroups: visibleGroups, showAggregate: showAggregate, surfaceStyle: .constant(surfaceStyle), showsControls: false).frame(width: 1200, height: 800).background(.white))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return }
            do { try png.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
        }
    }
}

struct HistogramBinControls: View {
    let unit: String
    @Binding var customWidth: Bool
    @Binding var customStart: Bool
    @Binding var halfFirst: Bool
    @Binding var width: String
    @Binding var start: String
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Toggle("Width", isOn: $customWidth); TextField("", text: $width).frame(width: 60).disabled(!customWidth); Text(unit) }
            Toggle("Make first bin half this width", isOn: $halfFirst)
            HStack { Toggle("Start at", isOn: $customStart); TextField("", text: $start).frame(width: 60).disabled(!customStart); Text(unit) }
        }.textFieldStyle(.roundedBorder).padding(8).background(Color(.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
