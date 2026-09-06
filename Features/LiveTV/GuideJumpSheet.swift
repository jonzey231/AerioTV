import SwiftUI

/// Guide jump-to-day (Roman via Discord, 2026-09-06): a day row and a
/// time-of-day row. Picking a day lands on the same clock time as now on
/// that day; a time pill moves to that hour. `onPick(nil)` means back to
/// now. tvOS presents it as a system sheet with the app's pills.
struct GuideJumpSheet: View {
    let daysBack: Int
    let daysAhead: Int
    let onPick: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dayOffset = 0
    @State private var slot: Slot = .sameTime

    enum Slot: CaseIterable {
        case sameTime, morning, afternoon, evening, prime, late
        var label: String {
            switch self {
            case .sameTime: return "Same Time"
            case .morning: return "Morning"
            case .afternoon: return "Afternoon"
            case .evening: return "Evening"
            case .prime: return "Prime Time"
            case .late: return "Late"
            }
        }
        var hour: Int? {
            switch self {
            case .sameTime: return nil
            case .morning: return 7
            case .afternoon: return 13
            case .evening: return 18
            case .prime: return 20
            case .late: return 23
            }
        }
    }

    private var dayOffsets: [Int] { Array(-max(0, daysBack)...max(1, daysAhead)) }

    private func dayLabel(_ offset: Int) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate(abs(offset) < 7 ? "EEEE" : "EEE d")
            return f.string(from: date(forDayOffset: offset, hour: nil))
        }
    }

    private func date(forDayOffset offset: Int, hour: Int?) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        guard let hour else { return day }
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    private var target: Date { date(forDayOffset: dayOffset, hour: slot.hour) }

    private var summary: String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: target)
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 30) {
            Text("Jump To")
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.textPrimary)
            pillRow(title: "Day") {
                ForEach(dayOffsets, id: \.self) { o in
                    Button(dayLabel(o)) { dayOffset = o }
                        .buttonStyle(MoviesPillStyle(isSelected: dayOffset == o))
                }
            }
            pillRow(title: "Time") {
                ForEach(Slot.allCases, id: \.self) { s in
                    Button(s.label) { slot = s }
                        .buttonStyle(MoviesPillStyle(isSelected: slot == s))
                }
            }
            Text(summary)
                .font(.system(size: 22))
                .foregroundColor(.textSecondary)
            HStack(spacing: 16) {
                Button("Go") { onPick(target) }
                    .buttonStyle(MoviesPillStyle(isSelected: true))
                Button("Back to Now") { onPick(nil) }
                    .buttonStyle(MoviesPillStyle(isSelected: false))
            }
            .focusSection()
        }
        .frame(width: 1100, alignment: .leading)
        .padding(48)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand { dismiss() }
        #else
        NavigationStack {
            Form {
                Section("Day") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(dayOffsets, id: \.self) { o in
                                chip(dayLabel(o), selected: dayOffset == o) { dayOffset = o }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                Section("Time") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Slot.allCases, id: \.self) { s in
                                chip(s.label, selected: slot == s) { slot = s }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                Section {
                    Button { onPick(target) } label: {
                        HStack { Spacer(); Text("Go to \(summary)").bold(); Spacer() }
                    }
                    Button { onPick(nil) } label: {
                        HStack { Spacer(); Text("Back to Now"); Spacer() }
                    }
                }
            }
            .navigationTitle("Jump To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        #endif
    }

    #if os(tvOS)
    private func pillRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { content() }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
            }
            .focusSection()
        }
    }
    #else
    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(selected ? .appBackground : .textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(selected ? Color.accentPrimary : Color.elevatedBackground))
        }
        .buttonStyle(.plain)
    }
    #endif
}
