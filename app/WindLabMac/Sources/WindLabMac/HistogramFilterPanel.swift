import SwiftUI

struct HistogramFilterPanel: View {
    let years: [Int]
    @Binding var selectedYear: String
    @Binding var selectedMonth: String
    @Binding var rangeStart: String
    @Binding var rangeEnd: String
    @Binding var filterMode: String
    @Binding var filterColumn: String
    @Binding var filterMin: String
    @Binding var filterMax: String
    let channels: [TimeSeriesChannel]
    let minDate: Date
    let maxDate: Date
    private let months = [("-", "<All>"), ("1", "Jan"), ("2", "Feb"), ("3", "Mar"), ("4", "Apr"), ("5", "May"), ("6", "Jun"), ("7", "Jul"), ("8", "Aug"), ("9", "Sep"), ("10", "Oct"), ("11", "Nov"), ("12", "Dec")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Filter by")
                Rectangle().fill(Color(.separatorColor)).frame(height: 1)
            }
            Text("Stored values; quality flags are not filtered.")
                .foregroundStyle(.secondary)
                .help("This distribution dialog does not currently apply quality-flag selection. Missing and negative wind-speed values are excluded.")
            HStack(spacing: 5) {
                CheckBox(isOn: binding("date"))
                Text("Date").frame(width: 64, alignment: .leading)
                Text("Year").foregroundStyle(.secondary).fixedSize()
                Picker("", selection: $selectedYear) {
                    Text("<All>").tag("-")
                    ForEach(years, id: \.self) { Text(String($0)).tag(String($0)) }
                }
                .labelsHidden().frame(width: 62)
                Text("Month").foregroundStyle(.secondary).fixedSize()
                Picker("", selection: $selectedMonth) {
                    ForEach(months, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 68)
            }
            HStack(spacing: 6) {
                CheckBox(isOn: binding("range"))
                Text("Date range").frame(width: 64, alignment: .leading)
                DatePicker("", selection: dateBinding(for: $rangeStart), in: minDate...maxDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(width: 88)
                Text("to").foregroundStyle(.secondary).fixedSize()
                DatePicker("", selection: dateBinding(for: $rangeEnd), in: minDate...maxDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(width: 88)
            }
            HStack(spacing: 6) {
                CheckBox(isOn: binding("column"))
                Text("Data column").frame(width: 64, alignment: .leading)
                Picker("", selection: $filterColumn) {
                    Text("<All>").tag("-")
                    ForEach(channels) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 202)
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 28)
                CheckBox(isOn: .constant(true)); Text("Min").foregroundStyle(.secondary)
                TextField("", text: $filterMin).textFieldStyle(.roundedBorder).frame(width: 54)
                CheckBox(isOn: .constant(true)); Text("Max").foregroundStyle(.secondary)
                TextField("", text: $filterMax).textFieldStyle(.roundedBorder).frame(width: 54)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .padding(8)
        .background(Color(.controlBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func binding(_ mode: String) -> Binding<Bool> {
        Binding {
            filterMode == mode
        } set: { value in
            filterMode = value ? mode : "none"
        }
    }

    private func dateBinding(for text: Binding<String>) -> Binding<Date> {
        Binding {
            Self.parseDate(text.wrappedValue) ?? minDate
        } set: { value in
            text.wrappedValue = Self.formatDate(min(max(value, minDate), maxDate))
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func formatDate(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }
}
