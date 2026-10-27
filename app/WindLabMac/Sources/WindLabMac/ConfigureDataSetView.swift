import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WindogCore

@MainActor
private final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    var onChange: ((NSColor) -> Void)?

    @objc func colorDidChange(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

struct ConfigureDataSetView: View {
    @State private var draft: DataSetConfiguration
    @State private var selectedColumnID: String?
    @State private var selectedTab = "Data Columns"
    @State private var previewLoadingID: String?
    @State private var previewError: String?
    @State private var isLoadingConfiguration = false
    @State private var configurationError: String?
    @State private var showsColorPalette = false
    @State private var cachedSource: WindExportDataSet?
    @State private var selectedColumnIDs = Set<String>()
    @State private var showsCalculation = false
    @State private var calculationSource = "<constant>"
    @State private var calculationMultiplier = 1.0
    @State private var calculationOffset = 0.0
    let sourceData: WindExportDataSet?
    let configuration: DataSetConfiguration
    let fileURL: URL?
    let apply: (DataSetConfiguration) -> Void
    let cancel: () -> Void

    init(configuration: DataSetConfiguration, fileURL: URL?, sourceData: WindExportDataSet? = nil, apply: @escaping (DataSetConfiguration) -> Void, cancel: @escaping () -> Void) {
        _draft = State(initialValue: configuration)
        _selectedColumnID = State(initialValue: configuration.columns.first?.id)
        _cachedSource = State(initialValue: sourceData)
        self.sourceData = sourceData
        self.configuration = configuration
        self.fileURL = fileURL
        self.apply = apply
        self.cancel = cancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Configure Data Set")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)

            Picker("", selection: $selectedTab) {
                Text("Data Columns").tag("Data Columns")
                Text("Data Set").tag("Data Set")
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            .padding(.bottom, 8)

            if selectedTab == "Data Columns" {
                dataColumnsView
            } else {
                ScrollView { dataSetView }
            }

            Text("All stored valid values · quality flags are not filtered · units edit labels only")
                .font(.caption2).foregroundStyle(.secondary)
            if let configurationError {
                Text(configurationError).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            HStack(spacing: 6) {
                Button("Help") {
                    let alert = NSAlert()
                    alert.messageText = "Configure Data Set"
                    alert.informativeText = "Edit column roles, units, heights, visibility and associations. Previews use all stored valid values; quality flags are not filtered. New TXT/CSV/TSV imports remain pending until OK. Templates use WindLab JSON and map columns by position. Calculated columns support constants and source × multiplier + offset. Unit labels do not convert samples. Cancel discards draft edits."
                    alert.runModal()
                }
                    .frame(width: 72)
                Spacer()
                Button("Cancel", action: cancel)
                    .frame(width: 72)
                Button("OK") {
                    do {
                        try ConfigurationEditing.validate(draft)
                        if let cachedSource { _ = try ConfigurationEditing.apply(cachedSource, draft) }
                        apply(draft)
                    } catch { configurationError = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .frame(width: 72)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .padding(.top, 8)
        .frame(width: panelSize.width, height: panelSize.height)
        .background(Color(.windowBackgroundColor))
        .sheet(isPresented: $showsCalculation) { calculationEditor }
        .onAppear {
            ensureSelection()
        }
        .task {
            await loadConfigurationIfNeeded()
        }
        .onChange(of: configurationSignature) { _, _ in
            draft = configuration
            selectedColumnID = configuration.columns.first?.id
            previewLoadingID = nil
            previewError = nil
            configurationError = nil
        }
    }

    private var panelSize: CGSize {
        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 1000)
        return CGSize(width: max(760, min(1320, available.width - 64)),
                      height: max(560, min(900, available.height - 100)))
    }
    private var propertiesWidth: CGFloat { max(280, panelSize.width * 0.34) }
    private let unitWidth: CGFloat = 44
    private let colorWidth: CGFloat = 24
    private let heightWidth: CGFloat = 50
    private let statWidth: CGFloat = 50
    private var tableWidth: CGFloat { panelSize.width - propertiesWidth - 38 }
    private var labelWidth: CGFloat { tableWidth - unitWidth - colorWidth - heightWidth - statWidth * 3 }

    private var dataColumnsView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("Add Column...", action: addColumn)
                Button("Delete Column(s)", action: deleteSelectedColumn)
                    .disabled(selectedColumnID == nil)
                Spacer()
                Button("Assign Default Colors to All Columns", action: assignDefaultColors)
                Spacer()
                Button("Save Template...", action: saveTemplate)
                Button("Load Template...", action: loadTemplate)
            }
            .font(.system(size: 12))

            HStack(spacing: 8) {
                columnTable
                    .frame(width: tableWidth)
                Divider()
                ScrollView { columnProperties }
                    .frame(width: propertiesWidth)
            }

            Text("Preview: \(selectedColumn?.label ?? "—")")
                .font(.system(size: 11)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                PDFPreviewChart(column: selectedColumn, isLoading: isSelectedPreviewLoading, errorMessage: previewError)
                DiurnalPreviewChart(column: selectedColumn, isLoading: isSelectedPreviewLoading, errorMessage: previewError)
                MonthlyStatisticsPreviewChart(column: selectedColumn, isLoading: isSelectedPreviewLoading, errorMessage: previewError)
            }
            .frame(height: max(170, min(220, panelSize.height * 0.25)))
        }
        .padding(.horizontal, 10)
        .task(id: previewSignature) {
            await loadSelectedPreviewIfNeeded()
        }
    }

    private var columnTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tableHeader("Label", width: labelWidth, alignment: .leading, leadingInset: 22)
                tableHeader("Units", width: unitWidth)
                tableHeader("", width: colorWidth)
                tableHeader("Height", width: heightWidth)
                tableHeader("Mean", width: statWidth)
                tableHeader("Min", width: statWidth)
                tableHeader("Max", width: statWidth)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(draft.columns) { column in
                        columnRow(column)
                    }
                }
            }
            .background(Color.white)
            .overlay {
                Rectangle().stroke(Color(.separatorColor), lineWidth: 1)
            }
            .overlay {
                if isLoadingConfiguration || configurationError != nil || draft.columns.isEmpty {
                    configurationStatusOverlay
                }
            }
        }
    }

    private func columnRow(_ column: DataColumnConfiguration) -> some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) {
                if selectedColumnIDs.contains(column.id) { selectedColumnIDs.remove(column.id) }
                else { selectedColumnIDs.insert(column.id) }
            } else { selectedColumnIDs = [column.id] }
            selectedColumnID = column.id
            previewError = nil
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: column.type))
                        .foregroundStyle(Color.chartColor(column.colorName))
                        .frame(width: 16)
                    Text(column.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(column.label)
                    Spacer()
                }
                .frame(width: labelWidth, alignment: .leading)
                .frame(minHeight: 30)
                .padding(.vertical, 3)
                Text(column.unit).frame(width: unitWidth, height: 22)
                Rectangle()
                    .fill(Color.chartColor(column.colorName))
                    .frame(width: colorWidth, height: 22)
                Text(heightText(column.height)).frame(width: heightWidth, height: 22)
                Text(column.mean).frame(width: statWidth, height: 22)
                Text(column.min).frame(width: statWidth, height: 22)
                Text(column.max).frame(width: statWidth, height: 22)
            }
            .font(.system(size: 12))
            .background((selectedColumnIDs.contains(column.id) || selectedColumnID == column.id) ? Color.accentColor.opacity(0.20) : Color.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var columnProperties: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Data column properties")
            if let binding = selectedColumnBinding {
                configRow("Type") {
                    Picker("", selection: binding.type) {
                        ForEach(columnTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                    .labelsHidden()
                }
                configRow("Subtype") {
                    Picker("Subtype", selection: binding.subtype) {
                        ForEach(["Mean", "Max", "Min", "Std. dev.", "Gust"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                configRow("Label") {
                    TextField("", text: binding.label, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .help(binding.wrappedValue.label)
                }
                configRow("Units") {
                    TextField("", text: binding.unit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                }
                configRow("Color") {
                    colorControl(binding.colorName)
                }
                configRow("Height") {
                    TextField("", value: binding.height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("m")
                }
                Toggle("Visible", isOn: binding.visible)
                    .toggleStyle(.checkbox)
                    .padding(.top, 2)

                sectionHeader("Associated data columns")
                    .padding(.top, 14)
                associationPicker("Std. dev.", binding.associated.stdDev)
                associationPicker("Max.", binding.associated.max)
                associationPicker("Min.", binding.associated.min)
                associationPicker("Speed", binding.associated.speed)

                Spacer()
                Button("Edit Calculation Properties...", action: editCalculation)
                    .disabled(binding.wrappedValue.calculation == nil)
                    .frame(width: 230)
                Button("Make Static Copy", action: makeStaticCopy)
                    .disabled(cachedSource == nil)
                    .frame(width: 230)
            } else {
                Text("No data column selected")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 12))
        .padding(10)
    }

    private var dataSetView: some View {
        VStack(alignment: .leading, spacing: 22) {
            dataSetSection("Site information") {
                formRow("Name") {
                    TextField("", text: $draft.dataSet.name)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(alignment: .top, spacing: 12) {
                    Text("Description")
                        .frame(width: 130, alignment: .trailing)
                    TextEditor(text: $draft.dataSet.description)
                        .frame(height: 90)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3).stroke(Color(.separatorColor))
                        }
                }
            }

            dataSetSection("Location") {
                formRow("Latitude") {
                    TextField("", value: $draft.dataSet.latitude, format: .number)
                        .textFieldStyle(.roundedBorder)
                    Text("° N")
                }
                formRow("Longitude") {
                    TextField("", value: $draft.dataSet.longitude, format: .number)
                        .textFieldStyle(.roundedBorder)
                    Text("° E")
                }
                formRow("Elevation") {
                    TextField("", value: $draft.dataSet.elevation, format: .number)
                        .textFieldStyle(.roundedBorder)
                    Text("m above sea level")
                    Button("Map") {}
                        .disabled(true)
                }
            }

            dataSetSection("Date and time") {
                staticRow("Data set starts:", draft.dataSet.start)
                staticRow("Data set ends:", draft.dataSet.end)
                staticRow("Data set duration:", draft.dataSet.duration)
                staticRow("Length of time step:", draft.dataSet.timeStep)
                formRow("Time stamps indicate") {
                    Picker("", selection: $draft.dataSet.timestampsIndicate) {
                        Text("Start").tag("Start")
                        Text("End").tag("End")
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Text("of time step")
                }
            }

            dataSetSection("Other") {
                formRow("Calm threshold") {
                    TextField("", value: $draft.dataSet.calmThreshold, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Text("m/s")
                }
                formRow("Invalid value") {
                    TextField("", value: $draft.dataSet.invalidValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                if !draft.dataSet.metadataSource.isEmpty {
                    Text(draft.dataSet.metadataSource)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 142)
                }
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 90)
        .padding(.top, 30)
    }

    private var selectedColumnBinding: Binding<DataColumnConfiguration>? {
        guard let selectedColumnID,
              let index = draft.columns.firstIndex(where: { $0.id == selectedColumnID }) else {
            return nil
        }
        return $draft.columns[index]
    }

    private var selectedColumn: DataColumnConfiguration? {
        guard let selectedColumnID else { return draft.columns.first }
        return draft.columns.first { $0.id == selectedColumnID }
    }

    private var isSelectedPreviewLoading: Bool {
        guard selectedColumnID != nil else { return false }
        return previewLoadingID == selectedColumnID
    }

    private var previewSignature: String {
        let c = selectedColumn
        return "\(selectedColumnID ?? "")|\(c?.type ?? "")|\(c?.subtype ?? "")|\(draft.dataSet.invalidValue)|\(draft.dataSet.timestampsIndicate)|\(c?.calculation?.sourceID ?? "")|\(c?.calculation?.multiplier ?? 1)|\(c?.calculation?.offset ?? 0)"
    }

    private func loadSelectedPreviewIfNeeded() async {
        guard let id = selectedColumnID, let source = cachedSource else { return }
        previewLoadingID = id
        previewError = nil
        let snapshot = draft
        let signature = previewSignature
        do {
            let (mapped, mean, minimum, maximum) = try await Task.detached(priority: .userInitiated) {
                let configured = try ConfigurationEditing.apply(source, snapshot)
                let preview = try NativeConfigurationAnalysis.preview(dataset: configured, channelID: id)
                let column = configured.columns.first { $0.id == id }!
                let stats = NativeConfigurationAnalysis.statistics(column: column)
                return (ColumnPreview(decoded: preview), NativeConfigurationAnalysis.formatted(stats.mean), NativeConfigurationAnalysis.formatted(stats.minimum), NativeConfigurationAnalysis.formatted(stats.maximum))
            }.value
            guard !Task.isCancelled, signature == previewSignature else { return }
            if let index = draft.columns.firstIndex(where: { $0.id == id }) {
                draft.columns[index].preview = mapped
                draft.columns[index].mean = mean; draft.columns[index].min = minimum; draft.columns[index].max = maximum
            }
            previewLoadingID = nil
        } catch {
            guard !Task.isCancelled, signature == previewSignature else { return }
            previewLoadingID = nil
            previewError = error.localizedDescription
        }
    }

    private var configurationStatusOverlay: some View {
        ZStack {
            Color.white.opacity(0.88)
            VStack(spacing: 8) {
                if isLoadingConfiguration {
                    ProgressView()
                    Text("Loading data columns...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if let configurationError {
                    Text(configurationError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    Text("No data columns loaded")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadConfigurationIfNeeded() async {
        guard !isLoadingConfiguration else { return }
        isLoadingConfiguration = true
        do {
            if cachedSource == nil, let fileURL {
                cachedSource = try await Task.detached { try WindogParser.exportDataSet(fileURL: fileURL) }.value
            }
            if draft.columns.isEmpty, let cachedSource {
                draft = DataSetConfiguration(decoded: NativeConfigurationAnalysis.configuration(dataset: cachedSource, fileName: fileURL?.lastPathComponent ?? cachedSource.name))
            }
            ensureSelection()
            isLoadingConfiguration = false
            await loadSelectedPreviewIfNeeded()
        } catch {
            isLoadingConfiguration = false
            configurationError = error.localizedDescription
        }
    }

    private var configurationSignature: String {
        configuration.columns.map(\.id).joined(separator: "\u{1f}")
    }

    private func ensureSelection() {
        if selectedColumnID == nil {
            selectedColumnID = draft.columns.first?.id
        }
    }

    private var columnTypes: [String] {
        ["Wind Speed", "Vert. Wind Speed", "Wind Direction", "Temperature", "Air Pressure", "Relative Humidity", "Wind Turbine Output", "Turbulence Intensity", "Air Density", "Wind Power Density", "Quality", "Other"]
    }

    private var colorNames: [String] {
        ["measured", "primary", "secondary", "accent", "brown", "violet", "yellow", "green2", "red", "purple", "orange", "blue2", "blue3", "blue4", "blue5", "blue6", "blue7", "blue8"]
    }

    private var presetColorHexes: [String] {
        [
            "#FF6F72", "#FFF86A", "#7AF07A", "#00E878", "#79E0E3", "#147FE8", "#EF69AE", "#E861E8",
            "#FF2A10", "#FFF000", "#63F000", "#08E83F", "#12CFCF", "#0F83B5", "#7F7DBB", "#EF2BE4",
            "#874140", "#FF7C3E", "#00E000", "#087C72", "#0E3F78", "#7678EE", "#8A0E42", "#F92B72",
            "#951000", "#FF8300", "#007F00", "#078143", "#1D36F2", "#0F2394", "#84208A", "#782FF0",
            "#590800", "#8A4D00", "#004C09", "#084D48", "#151D83", "#06093A", "#460B46", "#3A1678",
            "#000000", "#838700", "#848944", "#808080", "#3E8580", "#B8B8B8", "#4A084A", "#FFFFFF"
        ]
    }

    private var allColumnNames: [String] {
        ["<none>", "<nearest in height>"] + draft.columns.map(\.label)
    }

    private func tableHeader(_ text: String, width: CGFloat, alignment: Alignment = .center, leadingInset: CGFloat = 0) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.leading, leadingInset)
            .frame(width: width, height: 22, alignment: alignment)
            .background(Color(.controlBackgroundColor))
    }

    private func sectionHeader(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
            Rectangle().fill(Color(.separatorColor)).frame(height: 1)
        }
    }

    private func configRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 72, alignment: .leading)
            content()
        }
    }

    @ViewBuilder
    private func associationPicker(_ label: String, _ selection: Binding<String>) -> some View {
        configRow(label) {
            Picker("", selection: selection) {
                Text("<none>").tag("<none>")
                if label == "Speed" { Text("<nearest in height>").tag("<nearest in height>") }
                ForEach(associationCandidates(label)) { column in Text(column.label).tag(column.id) }
            }
            .labelsHidden()
            .help(associationLabel(selection.wrappedValue))
        }
        if selection.wrappedValue != "<none>" && selection.wrappedValue != "<nearest in height>" {
            Text(associationLabel(selection.wrappedValue))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 82)
        }
    }

    private func associationLabel(_ id: String) -> String {
        draft.columns.first { $0.id == id }?.label ?? id
    }

    private func colorControl(_ colorName: Binding<String>) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.chartColor(colorName.wrappedValue))
                .frame(width: 48, height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(.separatorColor), lineWidth: 1)
                }

            Button("More") {
                showsColorPalette.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .frame(width: 56, height: 24)
            .popover(isPresented: $showsColorPalette, arrowEdge: .bottom) {
                colorPalette(colorName)
            }
        }
    }

    private func colorPalette(_ colorName: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Basic colors")
                .font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 8), spacing: 6) {
                ForEach(presetColorHexes, id: \.self) { hex in
                    Button {
                        colorName.wrappedValue = hex
                        showsColorPalette = false
                    } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.chartColor(hex))
                            .frame(width: 24, height: 22)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color(.separatorColor), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button("Custom Color...") {
                showsColorPalette = false
                showColorPanel(for: colorName)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 260)
    }

    private func hexString(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        let red = max(0, min(255, Int(round(nsColor.redComponent * 255))))
        let green = max(0, min(255, Int(round(nsColor.greenComponent * 255))))
        let blue = max(0, min(255, Int(round(nsColor.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private func showColorPanel(for colorName: Binding<String>) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.color = NSColor(Color.chartColor(colorName.wrappedValue)).usingColorSpace(.sRGB) ?? .systemBlue
        ColorPanelBridge.shared.onChange = { color in
            colorName.wrappedValue = hexString(from: Color(nsColor: color))
        }
        panel.setTarget(ColorPanelBridge.shared)
        panel.setAction(#selector(ColorPanelBridge.colorDidChange(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    private func dataSetSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title)
            content()
        }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 130, alignment: .trailing)
            content()
        }
    }

    private func staticRow(_ label: String, _ value: String) -> some View {
        formRow(label) {
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func miniPanel(title: String) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 18)
            Rectangle()
                .fill(Color.white)
                .overlay {
                    ChartGrid(
                        xTicks: [0, 0.5, 1],
                        yTicks: [0, 0.5, 1],
                        xRange: 0...1,
                        yRange: 0...1,
                        origin: CGPoint(x: 24, y: 10),
                        size: CGSize(width: 230, height: 94)
                    )
                }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func heightText(_ height: Double?) -> String {
        guard let height else { return "" }
        return height.rounded() == height ? "\(Int(height)) m" : String(format: "%.1f m", height)
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "Wind Direction": return "location.north"
        case "Relative Humidity": return "drop.fill"
        case "Temperature": return "thermometer.medium"
        case "Air Pressure": return "barometer"
        case "Quality": return "star"
        default: return "wind"
        }
    }

    private func addColumn() {
        let newColumn = DataColumnConfiguration(
            id: "calculated-\(UUID().uuidString)",
            label: "New Column",
            unit: "",
            type: "Other",
            subtype: "Mean",
            colorName: colorNames[draft.columns.count % colorNames.count],
            height: nil,
            visible: true,
            mean: "-",
            min: "-",
            max: "-",
            associated: AssociatedColumns(stdDev: "<none>", min: "<none>", max: "<none>", speed: "<none>"),
            preview: .empty,
            calculation: ColumnCalculation(sourceID: nil)
        )
        draft.columns.append(newColumn)
        selectedColumnID = newColumn.id
        selectedColumnIDs = [newColumn.id]
        editCalculation()
    }

    private func deleteSelectedColumn() {
        guard let selectedColumnID else { return }
        let ids = selectedColumnIDs.union([selectedColumnID])
        draft.columns.removeAll { ids.contains($0.id) }
        for i in draft.columns.indices {
            if ids.contains(draft.columns[i].associated.stdDev) { draft.columns[i].associated.stdDev = "<none>" }
            if ids.contains(draft.columns[i].associated.min) { draft.columns[i].associated.min = "<none>" }
            if ids.contains(draft.columns[i].associated.max) { draft.columns[i].associated.max = "<none>" }
            if ids.contains(draft.columns[i].associated.speed) { draft.columns[i].associated.speed = "<nearest in height>" }
        }
        selectedColumnIDs = []
        self.selectedColumnID = draft.columns.first?.id
    }

    private func assignDefaultColors() {
        for index in draft.columns.indices {
            draft.columns[index].colorName = colorNames[index % colorNames.count]
        }
    }
}

private struct PreviewPanel<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
            content
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct PreviewAxisScale {
    let range: ClosedRange<Double>
    let ticks: [Double]
}

private func previewYAxisScale(for column: DataColumnConfiguration?, values: [Double], fallback: ClosedRange<Double> = 0...1) -> PreviewAxisScale {
    switch column?.type {
    case "Wind Direction":
        return PreviewAxisScale(range: 0...360, ticks: [0, 90, 180, 270, 360])
    case "Relative Humidity":
        return PreviewAxisScale(range: 0...100, ticks: [0, 25, 50, 75, 100])
    case "Air Pressure":
        return niceAxis(values: values, fallback: 95...105, includeZero: false, maxTickCount: 5)
    default:
        return niceAxis(values: values, fallback: fallback, includeZero: column?.unit == "m/s", maxTickCount: 5)
    }
}

private func previewPDFXAxisScale(for column: DataColumnConfiguration?, bars: [HistogramBar]) -> PreviewAxisScale {
    switch column?.type {
    case "Wind Direction":
        return PreviewAxisScale(range: 0...360, ticks: [0, 90, 180, 270, 360])
    case "Relative Humidity":
        return PreviewAxisScale(range: 0...100, ticks: [0, 25, 50, 75, 100])
    case "Air Pressure":
        let values = bars.flatMap { [$0.x - $0.width / 2, $0.x + $0.width / 2] }
        return niceAxis(values: values, fallback: 95...105, includeZero: false, maxTickCount: 5)
    default:
        let values = bars.flatMap { [$0.x - $0.width / 2, $0.x + $0.width / 2] }
        return niceAxis(values: values, fallback: 0...1, includeZero: column?.unit == "m/s", maxTickCount: 5)
    }
}

private func niceAxis(values: [Double], fallback: ClosedRange<Double>, includeZero: Bool, maxTickCount: Int) -> PreviewAxisScale {
    let finite = values.filter(\.isFinite)
    guard var lower = finite.min(), var upper = finite.max() else {
        return PreviewAxisScale(range: fallback, ticks: niceTicks(for: fallback, maxTickCount: maxTickCount))
    }
    if includeZero {
        lower = min(0, lower)
        upper = max(0, upper)
    }
    if abs(upper - lower) < 1e-9 {
        let padding = max(abs(upper) * 0.1, 1)
        lower -= padding
        upper += padding
    }
    let padding = max((upper - lower) * 0.06, 1e-9)
    lower = includeZero ? min(0, lower) : lower - padding
    upper += padding
    let ticks = niceTicks(for: lower...upper, maxTickCount: maxTickCount)
    return PreviewAxisScale(range: (ticks.first ?? lower)...(ticks.last ?? upper), ticks: ticks)
}

private func niceTicks(for range: ClosedRange<Double>, maxTickCount: Int) -> [Double] {
    let span = max(range.upperBound - range.lowerBound, 1e-9)
    let rawStep = span / Double(max(maxTickCount - 1, 1))
    let magnitude = pow(10, floor(log10(rawStep)))
    let residual = rawStep / magnitude
    let niceResidual: Double
    if residual <= 1 {
        niceResidual = 1
    } else if residual <= 2 {
        niceResidual = 2
    } else if residual <= 5 {
        niceResidual = 5
    } else {
        niceResidual = 10
    }
    let step = niceResidual * magnitude
    let start = floor(range.lowerBound / step) * step
    let end = ceil(range.upperBound / step) * step
    return Array(stride(from: start, through: end + step * 0.5, by: step)).filter { $0 >= start - 1e-9 && $0 <= end + 1e-9 }
}

private struct PDFPreviewChart: View {
    let column: DataColumnConfiguration?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        PreviewPanel(title: "PDF") {
            GeometryReader { geometry in
                let bars = column?.preview.pdf ?? []
                let xScale = previewPDFXAxisScale(for: column, bars: bars)
                let yScale = niceAxis(values: bars.map(\.y), fallback: 0...1, includeZero: true, maxTickCount: 5)
                let frame = PlotFrame(size: geometry.size, left: 36, right: 8, top: 8, bottom: 32)
                ZStack(alignment: .topLeading) {
                    PreviewGrid(frame: frame, xTicks: xScale.ticks, yTicks: yScale.ticks, xRange: xScale.range, yRange: yScale.range)
                    ForEach(bars) { bar in
                        let x0 = frame.x(bar.x - bar.width / 2, in: xScale.range)
                        let x1 = frame.x(bar.x + bar.width / 2, in: xScale.range)
                        let y = frame.y(bar.y, in: yScale.range)
                        Rectangle()
                            .fill(Color.chartColor(column?.colorName ?? "primary"))
                            .overlay(Rectangle().stroke(.black, lineWidth: 0.5))
                            .frame(width: max(x1 - x0, 1), height: frame.bottomY - y)
                            .position(x: (x0 + x1) / 2, y: y + (frame.bottomY - y) / 2)
                    }
                    PreviewAxes(frame: frame, xTicks: xScale.ticks, yTicks: yScale.ticks, xRange: xScale.range, yRange: yScale.range, xLabel: "Value (\(column?.unit ?? "-"))", yLabel: "Frequency (%)")
                    PreviewStatusOverlay(isLoading: isLoading, errorMessage: errorMessage, isEmpty: bars.isEmpty)
                }
            }
        }
    }
}

private struct DiurnalPreviewChart: View {
    let column: DataColumnConfiguration?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        PreviewPanel(title: "Mean Diurnal Profile") {
            GeometryReader { geometry in
                let points = column?.preview.diurnal ?? []
                let values = points.map(\.y)
                let yScale = previewYAxisScale(for: column, values: values, fallback: 0...2)
                let frame = PlotFrame(size: geometry.size, left: 36, right: 8, top: 8, bottom: 32)
                ZStack(alignment: .topLeading) {
                    PreviewGrid(frame: frame, xTicks: [0, 6, 12, 18, 24], yTicks: yScale.ticks, xRange: 0...24, yRange: yScale.range)
                    ForEach(points) { point in
                        let x0 = frame.x(point.x, in: 0...24)
                        let x1 = frame.x(point.x + 1, in: 0...24)
                        let y = frame.y(point.y, in: yScale.range)
                        let baseline = frame.y(min(max(0, yScale.range.lowerBound), yScale.range.upperBound), in: yScale.range)
                        Rectangle()
                            .fill(Color.chartColor(column?.colorName ?? "primary"))
                            .overlay(Rectangle().stroke(.black, lineWidth: 0.5))
                            .frame(width: max(x1 - x0 - 1, 1), height: abs(baseline - y))
                            .position(x: (x0 + x1) / 2, y: (y + baseline) / 2)
                    }
                    PreviewAxes(frame: frame, xTicks: [0, 6, 12, 18, 24], yTicks: yScale.ticks, xRange: 0...24, yRange: yScale.range, xLabel: "Time Of Day", yLabel: "Mean Value (\(column?.unit ?? "-"))")
                    PreviewStatusOverlay(isLoading: isLoading, errorMessage: errorMessage, isEmpty: points.isEmpty)
                }
            }
        }
    }
}

private struct MonthlyStatisticsPreviewChart: View {
    let column: DataColumnConfiguration?
    let isLoading: Bool
    let errorMessage: String?
    private let labels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    var body: some View {
        PreviewPanel(title: "Monthly Statistics") {
            GeometryReader { geometry in
                let stats = column?.preview.monthly ?? []
                let values = stats.flatMap { [$0.min, $0.q1, $0.mean, $0.q3, $0.max] }
                let yScale = previewYAxisScale(for: column, values: values, fallback: 0...5)
                let xTicks = Array(0..<12).map { Double($0) + 0.5 }
                let frame = PlotFrame(size: geometry.size, left: 36, right: 75, top: 8, bottom: 32)
                ZStack(alignment: .topLeading) {
                    PreviewGrid(frame: frame, xTicks: xTicks, yTicks: yScale.ticks, xRange: 0...12, yRange: yScale.range)
                    ForEach(stats) { item in
                        let center = frame.x(item.x + 0.5, in: 0...12)
                        let minY = frame.y(item.min, in: yScale.range)
                        let maxY = frame.y(item.max, in: yScale.range)
                        let q1Y = frame.y(item.q1, in: yScale.range)
                        let q3Y = frame.y(item.q3, in: yScale.range)
                        let meanY = frame.y(item.mean, in: yScale.range)
                        Path { path in
                            path.move(to: CGPoint(x: center, y: maxY))
                            path.addLine(to: CGPoint(x: center, y: minY))
                        }
                        .stroke(.black, lineWidth: 1)
                        Rectangle()
                            .fill(Color.chartColor(column?.colorName ?? "primary"))
                            .overlay(Rectangle().stroke(.black, lineWidth: 0.6))
                            .frame(width: 12, height: max(q1Y - q3Y, 1))
                            .position(x: center, y: (q1Y + q3Y) / 2)
                        Path { path in
                            path.move(to: CGPoint(x: center - 7, y: meanY))
                            path.addLine(to: CGPoint(x: center + 7, y: meanY))
                        }
                        .stroke(.black, lineWidth: 1)
                    }
                    PreviewAxes(frame: frame, xTicks: xTicks, yTicks: yScale.ticks, xRange: 0...12, yRange: yScale.range, xLabels: labels, xLabel: "", yLabel: "")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("max")
                        Text("avg daily max")
                        Text("mean")
                        Text("avg daily min")
                        Text("min")
                    }
                    .font(.system(size: 9))
                    .position(x: frame.rightX + 37, y: frame.topY + 34)
                    PreviewStatusOverlay(isLoading: isLoading, errorMessage: errorMessage, isEmpty: stats.isEmpty)
                }
            }
        }
    }
}

private struct PreviewStatusOverlay: View {
    let isLoading: Bool
    let errorMessage: String?
    let isEmpty: Bool

    var body: some View {
        if isLoading || errorMessage != nil || isEmpty {
            ZStack {
                Color.white.opacity(0.78)
                VStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading...")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Select a column")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct PlotFrame {
    let size: CGSize
    let left: CGFloat
    let right: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    var origin: CGPoint { CGPoint(x: left, y: top) }
    var plotSize: CGSize { CGSize(width: max(size.width - left - right, 10), height: max(size.height - top - bottom, 10)) }
    var bottomY: CGFloat { top + plotSize.height }
    var rightX: CGFloat { left + plotSize.width }
    var topY: CGFloat { top }

    func x(_ value: Double, in range: ClosedRange<Double>) -> CGFloat {
        left + CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1e-9)) * plotSize.width
    }

    func y(_ value: Double, in range: ClosedRange<Double>) -> CGFloat {
        top + plotSize.height - CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1e-9)) * plotSize.height
    }
}

private func ceilToMultiple(_ value: Double, step: Double) -> Double {
    max(step, ceil(value / step) * step)
}

private func multipleTicks(through upper: Double, step: Double) -> [Double] {
    Array(stride(from: 0.0, through: upper, by: step))
}

private struct PreviewGrid: View {
    let frame: PlotFrame
    let xTicks: [Double]
    let yTicks: [Double]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for index in 0...10 {
                    let x = frame.left + frame.plotSize.width * CGFloat(index) / 10
                    path.move(to: CGPoint(x: x, y: frame.top))
                    path.addLine(to: CGPoint(x: x, y: frame.bottomY))
                }
                for index in 0...6 {
                    let y = frame.top + frame.plotSize.height * CGFloat(index) / 6
                    path.move(to: CGPoint(x: frame.left, y: y))
                    path.addLine(to: CGPoint(x: frame.rightX, y: y))
                }
            }
            .stroke(Color(red: 0.92, green: 0.92, blue: 0.92), lineWidth: 0.6)
            Path { path in
                for tick in xTicks {
                    let x = frame.x(tick, in: xRange)
                    path.move(to: CGPoint(x: x, y: frame.top))
                    path.addLine(to: CGPoint(x: x, y: frame.bottomY))
                }
                for tick in yTicks {
                    let y = frame.y(tick, in: yRange)
                    path.move(to: CGPoint(x: frame.left, y: y))
                    path.addLine(to: CGPoint(x: frame.rightX, y: y))
                }
            }
            .stroke(Color(red: 0.78, green: 0.78, blue: 0.78), lineWidth: 0.8)
            Rectangle()
                .stroke(Color.black, lineWidth: 0.8)
                .frame(width: frame.plotSize.width, height: frame.plotSize.height)
                .position(x: frame.left + frame.plotSize.width / 2, y: frame.top + frame.plotSize.height / 2)
        }
    }
}

private struct PreviewAxes: View {
    let frame: PlotFrame
    let xTicks: [Double]
    let yTicks: [Double]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>
    var xLabels: [String]? = nil
    let xLabel: String
    let yLabel: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(yTicks.enumerated()), id: \.offset) { _, tick in
                Text(format(tick))
                    .font(.system(size: 9))
                    .position(x: frame.left - 18, y: frame.y(tick, in: yRange))
            }
            ForEach(Array(xTicks.enumerated()), id: \.offset) { index, tick in
                Text(xLabels?[safe: index] ?? format(tick))
                    .font(.system(size: 9))
                    .position(x: frame.x(tick, in: xRange), y: frame.bottomY + 12)
            }
            if !xLabel.isEmpty {
                Text(xLabel)
                    .font(.system(size: 9))
                    .position(x: frame.left + frame.plotSize.width / 2, y: frame.bottomY + 25)
            }
            if !yLabel.isEmpty {
                Text(yLabel)
                    .font(.system(size: 9))
                    .rotationEffect(.degrees(-90))
                    .position(x: 9, y: frame.top + frame.plotSize.height / 2)
            }
        }
    }

    private func format(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.001 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }
}

private extension ConfigureDataSetView {
    func associationCandidates(_ role: String) -> [DataColumnConfiguration] {
        draft.columns.filter { column in
            guard column.id != selectedColumnID else { return false }
            if role == "Speed" { return column.type == "Wind Speed" && column.subtype == "Mean" }
            let subtype = role == "Std. dev." ? "Std. dev." : role == "Min." ? "Min" : "Max"
            return column.type == selectedColumn?.type && column.subtype == subtype
        }
    }
    func saveTemplate() {
        let panel = NSSavePanel()
        panel.title = "Save WindLab Configuration Template"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Configuration.windlab-template.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ConfigurationEditing.validate(draft)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ConfigurationTemplate(draft)).write(to: url, options: .atomic)
        } catch { configurationError = error.localizedDescription }
    }
    func loadTemplate() {
        let panel = NSOpenPanel()
        panel.title = "Load WindLab Configuration Template"
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            draft = try JSONDecoder().decode(ConfigurationTemplate.self, from: Data(contentsOf: url)).applying(to: draft)
            configurationError = nil
            Task { await loadSelectedPreviewIfNeeded() }
        } catch { configurationError = error.localizedDescription }
    }
    func editCalculation() {
        guard let calculation = selectedColumn?.calculation else { return }
        calculationSource = calculation.sourceID ?? "<constant>"
        calculationMultiplier = calculation.multiplier
        calculationOffset = calculation.offset
        showsCalculation = true
    }
    var calculationEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Calculated Column").font(.headline)
            Text("Value = source × multiplier + offset. A constant uses the offset only.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Source", selection: $calculationSource) {
                Text("Constant").tag("<constant>")
                ForEach(draft.columns.filter { $0.id != selectedColumnID }) { Text($0.label).tag($0.id) }
            }
            TextField("Multiplier", value: $calculationMultiplier, format: .number).disabled(calculationSource == "<constant>")
            TextField("Offset / constant", value: $calculationOffset, format: .number)
            if selectedColumn?.calculation?.staticValues != nil { Text("Applying a formula replaces this static snapshot.").font(.caption) }
            HStack {
                Button("Cancel") { showsCalculation = false }
                Spacer()
                Button("Apply") {
                    guard let index = draft.columns.firstIndex(where: { $0.id == selectedColumnID }) else { return }
                    let previous = draft.columns[index].calculation
                    draft.columns[index].calculation = ColumnCalculation(sourceID: calculationSource == "<constant>" ? nil : calculationSource,
                        multiplier: calculationMultiplier, offset: calculationOffset)
                    do {
                        if let cachedSource { _ = try ConfigurationEditing.apply(cachedSource, draft) }
                        draft.columns[index].preview = .empty
                        showsCalculation = false
                        configurationError = nil
                        Task { await loadSelectedPreviewIfNeeded() }
                    } catch {
                        draft.columns[index].calculation = previous
                        configurationError = error.localizedDescription
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(20).frame(width: 460)
    }
    func makeStaticCopy() {
        guard let source = cachedSource, let selected = selectedColumn else { return }
        do {
            let configured = try ConfigurationEditing.apply(source, draft)
            guard let values = configured.columns.first(where: { $0.id == selected.id })?.values else { return }
            var copy = selected
            copy.id = "static-\(UUID().uuidString)"
            copy.label += " (static copy)"
            copy.calculation = ColumnCalculation(sourceID: nil, staticValues: values)
            draft.columns.append(copy)
            selectedColumnID = copy.id
            selectedColumnIDs = [copy.id]
        } catch { configurationError = error.localizedDescription }
    }
}
