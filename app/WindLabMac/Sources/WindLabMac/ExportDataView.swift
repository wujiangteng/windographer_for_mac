import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WindogCore

struct ExportDataView: View {
    let fileURL: URL
    let configuration: DataSetConfiguration
    let dismiss: () -> Void

    @State private var dataset: WindExportDataSet?
    @State private var format = WindExportFormat.csv
    @State private var selectedIDs: Set<String> = []
    @State private var speedID = ""
    @State private var directionID = ""
    @State private var sectors = 16
    @State private var binWidth = "1"
    @State private var latitude = "0"
    @State private var longitude = "0"
    @State private var height = ""
    @State private var includeSite = false
    @State private var missingValue = "-9999"
    @State private var missingSentinel = "9999"
    @State private var limitDates = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var busy = true
    @State private var error: String?
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Data").font(.title2)
            Text(fileURL.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            if let dataset {
                Form {
                    Picker("Format", selection: $format) {
                        ForEach(WindExportFormat.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    if format == .waspTab {
                        climateOptions(dataset)
                    } else {
                        Text("Columns (\(selectedIDs.count) selected)")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(dataset.columns, id: \.id) { column in
                                    Toggle(column.heading, isOn: Binding(
                                        get: { selectedIDs.contains(column.id) },
                                        set: { selected in
                                            if selected { selectedIDs.insert(column.id) }
                                            else { selectedIDs.remove(column.id) }
                                        }))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 125)
                        HStack {
                            Button("Select All") { selectedIDs = Set(dataset.columns.map(\.id)) }
                            Button("Clear") { selectedIDs = [] }
                        }
                        if format != .xlsx { TextField("Missing value", text: $missingValue) }
                    }
                    Toggle("Limit time range", isOn: $limitDates)
                    if limitDates {
                        DatePicker("From", selection: $start)
                        DatePicker("Through", selection: $end)
                    }
                    if format == .windographerText {
                        Toggle("Include site header", isOn: $includeSite)
                    }
                    if format == .waspTab || (format == .windographerText && includeSite) {
                        HStack {
                            TextField("Latitude", text: $latitude)
                            TextField("Longitude", text: $longitude)
                            TextField("Height (m)", text: $height)
                        }
                    }
                }
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .disabled(busy)
                Text(format == .waspTab
                     ? "Uses stored speed/direction pairs. Quality flags and seasonal corrections are not applied. Confirm site coordinates and measurement height."
                     : "Exports stored values with source timestamps and current column labels. Quality flags are not applied; computed-only columns have no stored values and are omitted.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if busy { ProgressView(dataset == nil ? "Reading data…" : "Writing export…") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let result { Text(result).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction).disabled(busy)
                Button("Export…", action: save).keyboardShortcut(.defaultAction)
                    .disabled(busy || dataset == nil || (format != .waspTab && selectedIDs.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 690, height: 620)
        .task { await load() }
        .onChange(of: speedID) { _, _ in updateHeight() }
    }

    private func climateOptions(_ dataset: WindExportDataSet) -> some View {
        Group {
            Picker("Wind speed", selection: $speedID) {
                Text("Choose a column").tag("")
                ForEach(dataset.columns.filter { $0.unit == "m/s" }, id: \.id) { Text($0.heading).tag($0.id) }
            }
            Picker("Wind direction", selection: $directionID) {
                Text("Choose a column").tag("")
                ForEach(dataset.columns.filter { ["deg", "°", "Deg"].contains($0.unit) }, id: \.id) { Text($0.heading).tag($0.id) }
            }
            Picker("Direction sectors", selection: $sectors) {
                ForEach([4, 8, 12, 16, 24, 36, 72], id: \.self) { Text("\($0)").tag($0) }
            }
            TextField("Speed bin width (m/s)", text: $binWidth)
            TextField("Ignore missing code (optional)", text: $missingSentinel)
        }
    }

    private func load() async {
        do {
            let url = fileURL
            let raw = try await Task.detached { try WindogParser.exportDataSet(fileURL: url) }.value
            let configured = Dictionary(uniqueKeysWithValues: configuration.columns.map { ($0.id, $0) })
            let loaded = try ConfigurationEditing.apply(raw, configuration)
            let columns = loaded.columns
            try loaded.validate()
            dataset = loaded
            selectedIDs = Set(columns.filter { configured[$0.id]?.visible ?? true }.map(\.id))
            speedID = columns.first { $0.unit == "m/s" }?.id ?? ""
            directionID = columns.first { ["deg", "°", "Deg"].contains($0.unit) }?.id ?? ""
            latitude = String(configuration.dataSet.latitude)
            longitude = String(configuration.dataSet.longitude)
            missingSentinel = String(configuration.dataSet.invalidValue)
            start = loaded.startDate
            end = start.addingTimeInterval(Double(loaded.rowCount - 1) * Double(loaded.timeStepMinutes) * 60)
            updateHeight()
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    private func updateHeight() {
        if let measured = configuration.columns.first(where: { $0.id == speedID })?.height {
            height = String(measured)
        } else if let label = dataset?.columns.first(where: { $0.id == speedID })?.label,
                  let range = label.range(of: #"\d+(?:\.\d+)?\s*m"#, options: .regularExpression) {
            height = label[range].replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
        } else {
            height = ""
        }
    }

    private func save() {
        guard let dataset else { return }
        error = nil
        result = nil
        do {
            let ids = format == .waspTab ? Set([speedID, directionID]) : selectedIDs
            let selected = try dataset.selecting(ids: ids, start: limitDates ? start : nil, end: limitDates ? end : nil)
            var site: WindExportSite?
            if format == .waspTab || (format == .windographerText && includeSite) {
                guard let lat = Double(latitude), let lon = Double(longitude), let h = Double(height) else {
                    throw WindogError.invalid("enter numeric latitude, longitude and measurement height")
                }
                site = WindExportSite(latitude: lat, longitude: lon, height: h)
                try site!.validate()
            }
            var climate: WAsPExportOptions?
            if format == .waspTab {
                guard let width = Double(binWidth), missingSentinel.isEmpty || Double(missingSentinel) != nil else {
                    throw WindogError.invalid("invalid bin width or missing code")
                }
                climate = WAsPExportOptions(speedID: speedID, directionID: directionID, sectors: sectors,
                                           binWidth: width, site: site!, missingSentinel: Double(missingSentinel))
            }
            let panel = NSSavePanel()
            panel.title = "Export Data"
            panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + "-Exported." + format.fileExtension
            panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
            panel.allowsOtherFileTypes = false
            let format = format
            let missingValue = missingValue
            let exportSite = site
            let climateOptions = climate
            panel.begin { response in
                guard response == .OK, let destination = panel.url else { return }
                if destination.standardizedFileURL.resolvingSymlinksInPath() == fileURL.standardizedFileURL.resolvingSymlinksInPath() {
                    error = "Choose a different filename to keep the source data intact."
                    return
                }
                busy = true
                Task {
                    do {
                        try await Task.detached {
                            switch format {
                            case .xlsx: try ExcelDataExporter.write(selected, to: destination)
                            case .waspTab: try WAsPDataExporter.write(selected, options: climateOptions!, to: destination)
                            default:
                                try DelimitedDataExporter.write(selected, format: format, to: destination,
                                                                missingValue: missingValue, site: exportSite)
                            }
                        }.value
                        result = "Exported to \(destination.path)"
                    } catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}
