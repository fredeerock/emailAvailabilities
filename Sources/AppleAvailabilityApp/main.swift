import SwiftUI
import EventKit
import AppKit

struct BusyBlock {
    let start: Date
    let end: Date
}

struct CalendarChoice: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let color: Color
    var isSelected: Bool
}

enum OutputStyle: String, CaseIterable, Identifiable {
    case numbered = "numbered"
    case casual = "casual"
    case friendly = "friendly"
    case professional = "professional"
    case formal = "formal"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .numbered: return "Numbered"
        case .casual: return "Casual"
        case .friendly: return "Friendly"
        case .professional: return "Professional"
        case .formal: return "Formal"
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case suggestedOptions = "suggested_options"
    case freeStretches = "free_stretches"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .suggestedOptions: return "Suggested options"
        case .freeStretches: return "Free stretches"
        }
    }
}

@MainActor
final class AvailabilityViewModel: ObservableObject {
    @Published var meetingMinutes: Int = 60
    @Published var startDate: Date = Date()
    @Published var endDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @Published var dayStartTime: Date = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @Published var dayEndTime: Date = Calendar.current.date(from: DateComponents(hour: 16, minute: 0)) ?? Date()
    @Published var slotStepMinutes: Int = 30
    @Published var leadHours: Int = 8
    @Published var maxOptions: Int = 5
    @Published var dateBias: Double = 0.0
    @Published var outputStyle: OutputStyle = .numbered
    @Published var outputMode: OutputMode = .freeStretches
    @Published var minimumFreeStretchMinutes: Int = 60
    @Published var maxFreeStretchOptions: Int = 5
    @Published var weekdaysOnly: Bool = true

    @Published var statusText: String = "Click Generate Availability"
    @Published var outputText: String = ""
    @Published var calendars: [CalendarChoice] = []

    private let eventStore = EKEventStore()

    func generateAvailability() {
        Task {
            do {
                try validateInputs()
                try await ensureCalendarAccess()
                loadCalendarsIfNeeded()

                let selectedIDs = Set(calendars.filter { $0.isSelected }.map { $0.id })
                if selectedIDs.isEmpty {
                    throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select at least one calendar."])
                }

                let cal = Calendar.current
                let rangeStart = cal.startOfDay(for: startDate)
                guard let endInclusiveDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDate)) else {
                    throw NSError(domain: "Range", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid end date"])
                }

                let busyBlocks = fetchBusyBlocks(start: rangeStart, end: endInclusiveDay, selectedIDs: selectedIDs)
                if outputMode == .suggestedOptions {
                    let options = buildAvailability(rangeStart: rangeStart, rangeEnd: endInclusiveDay, busy: busyBlocks)

                    if options.isEmpty {
                        statusText = "No available slots in selected range."
                        outputText = ""
                        return
                    }

                    outputText = formatOutput(options)
                    statusText = "Generated \(options.count) options."
                } else {
                    let stretches = buildFreeStretches(rangeStart: rangeStart, rangeEnd: endInclusiveDay, busy: busyBlocks)
                    if stretches.isEmpty {
                        statusText = "No free stretches meet your minimum in selected range."
                        outputText = ""
                        return
                    }

                    outputText = formatFreeStretchOutput(stretches)
                    statusText = "Found \(stretches.count) free stretches."
                }
            } catch {
                statusText = error.localizedDescription
            }
        }
    }

    func copyOutput() {
        let text = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = "No output to copy."
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = "Copied to clipboard."
    }

    func preloadCalendarsOnLaunch() {
        if hasCalendarReadAccess() {
            loadCalendarsIfNeeded()
        } else {
            statusText = "Click Generate to grant calendar access."
        }
    }

    func setAllCalendarsSelected(_ selected: Bool) {
        for idx in calendars.indices {
            calendars[idx].isSelected = selected
        }
    }

    private func validateInputs() throws {
        if meetingMinutes < 5 {
            throw NSError(domain: "Input", code: 1, userInfo: [NSLocalizedDescriptionKey: "Meeting length must be at least 5 minutes."])
        }
        if slotStepMinutes < 5 {
            throw NSError(domain: "Input", code: 1, userInfo: [NSLocalizedDescriptionKey: "Slot step must be at least 5 minutes."])
        }
        if maxOptions < 1 {
            throw NSError(domain: "Input", code: 1, userInfo: [NSLocalizedDescriptionKey: "Number of options must be at least 1."])
        }
        if minimumFreeStretchMinutes < 5 {
            throw NSError(domain: "Input", code: 1, userInfo: [NSLocalizedDescriptionKey: "Minimum free stretch must be at least 5 minutes."])
        }
        if maxFreeStretchOptions < 1 {
            throw NSError(domain: "Input", code: 1, userInfo: [NSLocalizedDescriptionKey: "Max free options must be at least 1."])
        }

        let cal = Calendar.current
        let startDay = cal.startOfDay(for: startDate)
        let endDay = cal.startOfDay(for: endDate)
        if endDay < startDay {
            throw NSError(domain: "Input", code: 1, userInfo: [NSLocalizedDescriptionKey: "End date must be on or after start date."])
        }

        let startHM = hourMinute(from: dayStartTime)
        let endHM = hourMinute(from: dayEndTime)
        let startMins = startHM.hour * 60 + startHM.minute
        let endMins = endHM.hour * 60 + endHM.minute
        if endMins <= startMins {
            throw NSError(domain: "Input", code: 1, userInfo: [NSLocalizedDescriptionKey: "Day end must be later than day start."])
        }
        if meetingMinutes > (endMins - startMins) {
            throw NSError(domain: "Input", code: 1, userInfo: [NSLocalizedDescriptionKey: "Meeting length exceeds daily time window."])
        }
    }

    private func ensureCalendarAccess() async throws {
        if hasCalendarReadAccess() {
            return
        }

        if #available(macOS 14.0, *) {
            let granted = try await eventStore.requestFullAccessToEvents()
            if !granted || !hasCalendarReadAccess() {
                throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access denied. Enable Quick Availability in System Settings > Privacy & Security > Calendars."])
            }
        } else {
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            if !granted || !hasCalendarReadAccess() {
                throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access denied. Enable Quick Availability in System Settings > Privacy & Security > Calendars."])
            }
        }
    }

    private func hasCalendarReadAccess() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess || status == .authorized
        }
        return status == .authorized
    }

    private func fetchBusyBlocks(start: Date, end: Date, selectedIDs: Set<String>) -> [BusyBlock] {
        let selectedCalendars = eventStore.calendars(for: .event).filter { selectedIDs.contains($0.calendarIdentifier) }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: selectedCalendars)
        let events = eventStore.events(matching: predicate)
        let blocks = events.compactMap { event -> BusyBlock? in
            if event.isDetached { return nil }
            if event.endDate <= event.startDate { return nil }
            return BusyBlock(start: event.startDate, end: event.endDate)
        }
        return mergeOverlaps(blocks.sorted { $0.start < $1.start })
    }

    private func loadCalendarsIfNeeded() {
        if calendars.isEmpty {
            loadCalendars(forceReload: true)
        }
    }

    private func loadCalendars(forceReload: Bool = false) {
        let ekCalendars = eventStore.calendars(for: .event)
            .filter { $0.allowsContentModifications || !$0.isImmutable } // include normal user-visible calendars
            .sorted {
                if $0.source.title == $1.source.title {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.source.title.localizedCaseInsensitiveCompare($1.source.title) == .orderedAscending
            }

        let selectedSet: Set<String>
        if forceReload || calendars.isEmpty {
            if let first = ekCalendars.first {
                selectedSet = [first.calendarIdentifier]
            } else {
                selectedSet = []
            }
        } else {
            selectedSet = Set(calendars.filter { $0.isSelected }.map { $0.id })
        }

        calendars = ekCalendars.map { cal in
            CalendarChoice(
                id: cal.calendarIdentifier,
                title: cal.title,
                subtitle: cal.source.title,
                color: Color(nsColor: NSColor(cgColor: cal.cgColor) ?? .systemBlue),
                isSelected: selectedSet.contains(cal.calendarIdentifier)
            )
        }
    }

    private func buildAvailability(rangeStart: Date, rangeEnd: Date, busy: [BusyBlock]) -> [Date] {
        let cal = Calendar.current
        let startHM = hourMinute(from: dayStartTime)
        let endHM = hourMinute(from: dayEndTime)
        let duration = TimeInterval(meetingMinutes * 60)
        let step = TimeInterval(slotStepMinutes * 60)
        let earliest = max(rangeStart, Date().addingTimeInterval(TimeInterval(leadHours * 3600)))

        var cursor = cal.startOfDay(for: rangeStart)
        var candidates: [Date] = []

        while cursor < rangeEnd {
            let weekday = cal.component(.weekday, from: cursor)
            let isWeekday = (2...6).contains(weekday)
            if !weekdaysOnly || isWeekday {
                guard
                    let windowStart = cal.date(bySettingHour: startHM.hour, minute: startHM.minute, second: 0, of: cursor),
                    let windowEnd = cal.date(bySettingHour: endHM.hour, minute: endHM.minute, second: 0, of: cursor)
                else {
                    break
                }

                var slot = ceilToStep(max(windowStart, earliest), step: step)
                while slot < windowEnd {
                    let slotEnd = slot.addingTimeInterval(duration)
                    if slotEnd > windowEnd || slotEnd > rangeEnd { break }
                    if !hasOverlap(slotStart: slot, slotEnd: slotEnd, blocks: busy) {
                        candidates.append(slot)
                    }
                    slot = slot.addingTimeInterval(step)
                }
            }

            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return chooseSpread(
            candidates: candidates,
            desiredCount: maxOptions,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            dateBias: dateBias
        )
    }

    private func chooseSpread(candidates: [Date], desiredCount: Int, rangeStart: Date, rangeEnd: Date, dateBias: Double) -> [Date] {
        if candidates.count <= desiredCount { return candidates.sorted() }

        let sortedCandidates = candidates.sorted()
        if abs(dateBias) < 0.05 {
            return chooseRandomlySpaced(candidates: sortedCandidates, desiredCount: desiredCount)
        }

        var selected: [Date] = []
        var seenDays: Set<String> = []
        var seenBuckets: Set<String> = []
        let span = max(rangeEnd.timeIntervalSince(rangeStart), 1)
        let biasStrength = min(max(abs(dateBias), 0), 1)
        let targetPosition = (dateBias + 1) / 2 // -1 => start, +1 => end

        while selected.count < desiredCount {
            var best: Date?
            var bestScore = -Double.greatestFiniteMagnitude

            for slot in sortedCandidates where !selected.contains(slot) {
                let position = min(max(slot.timeIntervalSince(rangeStart) / span, 0), 1)
                let biasScore = 1 - abs(position - targetPosition)

                var nearest = Double.greatestFiniteMagnitude
                for picked in selected {
                    nearest = min(nearest, abs(slot.timeIntervalSince(picked)))
                }

                let distanceScore = selected.isEmpty ? 0.7 : min(1, nearest / span)
                let dayBonus = seenDays.contains(dayKey(slot)) ? 0.0 : (0.24 * (1 - 0.7 * biasStrength))
                let bucketBonus = seenBuckets.contains(timeBucket(slot)) ? 0.0 : (0.18 * (1 - 0.6 * biasStrength))
                let closePenalty = nearest < 7200 ? (0.24 * (1 - 0.75 * biasStrength)) : 0.0

                let biasWeight = 0.25 + 0.55 * biasStrength
                let distanceWeight = 0.55 - 0.35 * biasStrength
                let score = biasWeight * biasScore + distanceWeight * distanceScore + dayBonus + bucketBonus - closePenalty
                if score > bestScore {
                    bestScore = score
                    best = slot
                }
            }

            guard let chosen = best else { break }
            selected.append(chosen)
            seenDays.insert(dayKey(chosen))
            seenBuckets.insert(timeBucket(chosen))
        }

        return selected.sorted()
    }

    private func chooseRandomlySpaced(candidates: [Date], desiredCount: Int) -> [Date] {
        guard desiredCount > 0 else { return [] }
        guard candidates.count > desiredCount else { return candidates.sorted() }

        var picked: [Date] = []
        for index in 0..<desiredCount {
            let start = Int((Double(index) / Double(desiredCount)) * Double(candidates.count))
            let end = Int((Double(index + 1) / Double(desiredCount)) * Double(candidates.count)) - 1
            let lower = max(0, min(start, candidates.count - 1))
            let upper = max(lower, min(end, candidates.count - 1))
            let chosenIndex = Int.random(in: lower...upper)
            picked.append(candidates[chosenIndex])
        }
        return picked.sorted()
    }

    private func buildFreeStretches(rangeStart: Date, rangeEnd: Date, busy: [BusyBlock]) -> [BusyBlock] {
        let cal = Calendar.current
        let startHM = hourMinute(from: dayStartTime)
        let endHM = hourMinute(from: dayEndTime)
        let earliest = max(rangeStart, Date().addingTimeInterval(TimeInterval(leadHours * 3600)))
        let minDuration = TimeInterval(minimumFreeStretchMinutes * 60)

        var cursor = cal.startOfDay(for: rangeStart)
        var stretches: [BusyBlock] = []

        while cursor < rangeEnd {
            let weekday = cal.component(.weekday, from: cursor)
            let isWeekday = (2...6).contains(weekday)

            if !weekdaysOnly || isWeekday {
                guard
                    let dayStart = cal.date(bySettingHour: startHM.hour, minute: startHM.minute, second: 0, of: cursor),
                    let dayEnd = cal.date(bySettingHour: endHM.hour, minute: endHM.minute, second: 0, of: cursor)
                else {
                    break
                }

                let windowStart = max(dayStart, earliest)
                let windowEnd = min(dayEnd, rangeEnd)

                if windowStart < windowEnd {
                    let dayBusy = busy
                        .filter { $0.end > windowStart && $0.start < windowEnd }
                        .map { BusyBlock(start: max($0.start, windowStart), end: min($0.end, windowEnd)) }
                        .sorted { $0.start < $1.start }

                    var freeCursor = windowStart
                    for block in dayBusy {
                        if block.start > freeCursor {
                            let free = BusyBlock(start: freeCursor, end: block.start)
                            if free.end.timeIntervalSince(free.start) >= minDuration {
                                stretches.append(free)
                            }
                        }
                        if block.end > freeCursor {
                            freeCursor = block.end
                        }
                    }

                    if windowEnd > freeCursor {
                        let free = BusyBlock(start: freeCursor, end: windowEnd)
                        if free.end.timeIntervalSince(free.start) >= minDuration {
                            stretches.append(free)
                        }
                    }
                }
            }

            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return Array(stretches.prefix(maxFreeStretchOptions))
    }

    private func formatOutput(_ slots: [Date]) -> String {
        let duration = TimeInterval(meetingMinutes * 60)

        let dateCasual = DateFormatter()
        dateCasual.dateFormat = "EEE M/d"

        let dateFriendly = DateFormatter()
        dateFriendly.dateFormat = "EEE, MMM d"

        let dateFormal = DateFormatter()
        dateFormal.dateFormat = "EEEE, MMMM d, yyyy"

        let timeStandard = DateFormatter()
        timeStandard.dateFormat = "h:mm a"

        let timeCompact = DateFormatter()
        timeCompact.dateFormat = "h:mma"

        let lines = slots.enumerated().map { idx, slot in
            let end = slot.addingTimeInterval(duration)

            switch outputStyle {
            case .numbered:
                return "\(idx + 1)) \(dateFriendly.string(from: slot)): \(timeStandard.string(from: slot)) - \(timeStandard.string(from: end))"
            case .casual:
                return "\(dateCasual.string(from: slot)) \(timeCompact.string(from: slot).lowercased())-\(timeCompact.string(from: end).lowercased())"
            case .friendly:
                return "\(dateFriendly.string(from: slot)) • \(timeStandard.string(from: slot)) to \(timeStandard.string(from: end))"
            case .professional:
                return "\(dateFriendly.string(from: slot)) | \(timeStandard.string(from: slot)) - \(timeStandard.string(from: end))"
            case .formal:
                return "\(dateFormal.string(from: slot)) | \(timeStandard.string(from: slot)) to \(timeStandard.string(from: end))"
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatFreeStretchOutput(_ stretches: [BusyBlock]) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"

        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"

        return stretches.enumerated().map { idx, stretch in
            return "\(idx + 1)) \(df.string(from: stretch.start)): \(tf.string(from: stretch.start)) - \(tf.string(from: stretch.end))"
        }.joined(separator: "\n")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }

    private func mergeOverlaps(_ blocks: [BusyBlock]) -> [BusyBlock] {
        guard !blocks.isEmpty else { return [] }
        var merged: [BusyBlock] = [blocks[0]]

        for block in blocks.dropFirst() {
            var last = merged.removeLast()
            if block.start <= last.end {
                if block.end > last.end {
                    last = BusyBlock(start: last.start, end: block.end)
                }
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(block)
            }
        }
        return merged
    }

    private func hasOverlap(slotStart: Date, slotEnd: Date, blocks: [BusyBlock]) -> Bool {
        for block in blocks {
            if block.end <= slotStart { continue }
            if block.start >= slotEnd { return false }
            return true
        }
        return false
    }

    private func ceilToStep(_ value: Date, step: TimeInterval) -> Date {
        let t = value.timeIntervalSince1970
        let rounded = ceil(t / step) * step
        return Date(timeIntervalSince1970: rounded)
    }

    private func hourMinute(from date: Date) -> (hour: Int, minute: Int) {
        let cal = Calendar.current
        return (cal.component(.hour, from: date), cal.component(.minute, from: date))
    }

    private func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private func timeBucket(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        if hour < 11 { return "morning" }
        if hour < 14 { return "midday" }
        if hour < 17 { return "afternoon" }
        return "evening"
    }
}

struct ContentView: View {
    @StateObject private var vm = AvailabilityViewModel()
    @State private var showStartDatePicker = false
    @State private var showEndDatePicker = false
    @State private var showSettingsOptions = false
    @State private var dayStartInput = ""
    @State private var dayEndInput = ""
    @State private var startDateInput = ""
    @State private var endDateInput = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.93, green: 0.96, blue: 0.98),
                    Color(red: 0.96, green: 0.94, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.blue.opacity(0.15))
                .frame(width: 320, height: 320)
                .blur(radius: 40)
                .offset(x: -340, y: -220)

            Circle()
                .fill(Color.teal.opacity(0.16))
                .frame(width: 280, height: 280)
                .blur(radius: 40)
                .offset(x: 360, y: 230)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick Availability")
                        .font(.system(size: 34, weight: .bold, design: .rounded))

                    Text("Set your date range, pick calendars, then click Generate and Copy.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                GeometryReader { proxy in
                    let isStacked = proxy.size.width < 1040

                    ScrollView {
                        if isStacked {
                            VStack(alignment: .leading, spacing: 12) {
                                settingsCard
                                outputCard
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 2)
                        } else {
                            HStack(alignment: .top, spacing: 16) {
                                settingsCard
                                    .frame(width: 390, alignment: .top)

                                VStack(alignment: .leading, spacing: 12) {
                                    outputCard
                                        .frame(width: 460)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 540, minHeight: 680)
        .onAppear {
            dayStartInput = formattedTime(vm.dayStartTime)
            dayEndInput = formattedTime(vm.dayEndTime)
            startDateInput = displayDate(vm.startDate)
            endDateInput = displayDate(vm.endDate)
        }
        .onChange(of: vm.startDate) { _ in
            startDateInput = displayDate(vm.startDate)
        }
        .onChange(of: vm.endDate) { _ in
            endDateInput = displayDate(vm.endDate)
        }
        .task {
            vm.preloadCalendarsOnLaunch()
        }
    }

    private var statusColor: Color {
        let lower = vm.statusText.lowercased()
        if lower.contains("generated") || lower.contains("copied") {
            return .green
        }
        if lower.contains("denied") || lower.contains("must") || lower.contains("invalid") {
            return .red
        }
        return .secondary
    }

    @ViewBuilder
    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    SectionHeader(title: "Settings", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: showSettingsOptions ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showSettingsOptions.toggle()
                    }
                }

                settingsGroup {
                    settingRow("Start date") {
                        DatePicker("", selection: $vm.startDate, displayedComponents: [.date])
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .frame(width: 186, alignment: .trailing)
                    }

                    settingRow("End date") {
                        DatePicker("", selection: $vm.endDate, displayedComponents: [.date])
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .frame(width: 186, alignment: .trailing)
                    }
                }

                if showSettingsOptions {
                    settingsGroup {
                        Text("Schedule Window")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        settingRow("Day start") {
                            DatePicker("", selection: $vm.dayStartTime, displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .frame(width: 186, alignment: .trailing)
                        }

                        settingRow("Day end") {
                            DatePicker("", selection: $vm.dayEndTime, displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .frame(width: 186, alignment: .trailing)
                        }

                        settingRow("Weekdays only") {
                            Toggle("", isOn: $vm.weekdaysOnly)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        Divider()

                        Text("Option Generation")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        settingRow("Output mode") {
                            Picker("", selection: $vm.outputMode) {
                                ForEach(OutputMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 186, alignment: .trailing)
                        }

                        if vm.outputMode == .suggestedOptions {
                            settingRow("Meeting length") {
                                Picker("", selection: $vm.meetingMinutes) {
                                    ForEach([15, 30, 45, 60, 75, 90, 120, 150, 180], id: \.self) { mins in
                                        Text("\(mins) min").tag(mins)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 140, alignment: .trailing)
                            }

                            settingRow("Slot step") {
                                Picker("", selection: $vm.slotStepMinutes) {
                                    ForEach([15, 30, 45, 60], id: \.self) { mins in
                                        Text("\(mins) min").tag(mins)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 140, alignment: .trailing)
                            }

                            settingRow("Max options") {
                                Picker("", selection: $vm.maxOptions) {
                                    ForEach(1...20, id: \.self) { count in
                                        Text("\(count)").tag(count)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 140, alignment: .trailing)
                            }

                            settingRow("Date bias") {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Slider(value: $vm.dateBias, in: -1...1, step: 0.5)
                                        .frame(width: 186)
                                    HStack(spacing: 0) {
                                        Text("Sooner")
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("Random")
                                            .frame(maxWidth: .infinity, alignment: .center)
                                        Text("Later")
                                            .frame(maxWidth: .infinity, alignment: .trailing)
                                    }
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 186)
                                }
                            }

                            settingRow("Output style") {
                                Picker("", selection: $vm.outputStyle) {
                                    ForEach(OutputStyle.allCases) { style in
                                        Text(style.label).tag(style)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 186, alignment: .trailing)
                            }
                        } else {
                            settingRow("Min free stretch") {
                                Picker("", selection: $vm.minimumFreeStretchMinutes) {
                                    ForEach([15, 30, 45, 60, 90, 120, 180], id: \.self) { mins in
                                        Text("\(mins) min").tag(mins)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 186, alignment: .trailing)
                            }

                            settingRow("Max free options") {
                                Picker("", selection: $vm.maxFreeStretchOptions) {
                                    ForEach(1...20, id: \.self) { count in
                                        Text("\(count)").tag(count)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 140, alignment: .trailing)
                            }
                        }

                        settingRow("Lead time") {
                            Picker("", selection: $vm.leadHours) {
                                ForEach([0, 1, 2, 4, 8, 12, 24, 48], id: \.self) { hours in
                                    Text("\(hours) hr").tag(hours)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 140, alignment: .trailing)
                        }

                        Divider()

                        Text("Calendars Used")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        if vm.calendars.isEmpty {
                            Text("Loading calendars. If prompted, allow calendar access.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 10) {
                                Button("Select All") { vm.setAllCalendarsSelected(true) }
                                    .buttonStyle(.borderless)
                                Button("Clear") { vm.setAllCalendarsSelected(false) }
                                    .buttonStyle(.borderless)
                                Spacer()
                                Text("\(vm.calendars.filter { $0.isSelected }.count) selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach($vm.calendars) { $calendar in
                                        calendarRow($calendar)
                                    }
                                }
                                .padding(8)
                            }
                            .frame(minHeight: 120, maxHeight: 200)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                            )
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        vm.generateAvailability()
                    } label: {
                        Label("Generate", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    @ViewBuilder
    private var outputCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Output", systemImage: "text.alignleft")

                Text(vm.statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(statusColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                TextEditor(text: $vm.outputText)
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 240)

                Button {
                    vm.copyOutput()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func formattedTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func parseTypedTime(_ input: String) -> Date? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        if let parsed = formatter.date(from: trimmed) {
            return parsed
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateStyle = .none

        for format in ["h:mm a", "h:mma", "h a", "ha", "H:mm", "HH:mm"] {
            fallback.dateFormat = format
            if let parsed = fallback.date(from: trimmed) {
                return parsed
            }
        }

        return nil
    }

    private func parseTypedDate(_ input: String) -> Date? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        if let parsed = formatter.date(from: trimmed) {
            return Calendar.current.startOfDay(for: parsed)
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeStyle = .none
        for format in ["M/d/yyyy", "MM/dd/yyyy", "M/d/yy", "yyyy-MM-dd"] {
            fallback.dateFormat = format
            if let parsed = fallback.date(from: trimmed) {
                return Calendar.current.startOfDay(for: parsed)
            }
        }

        return nil
    }

    private func commitStartDateInput() {
        if let parsed = parseTypedDate(startDateInput) {
            vm.startDate = parsed
        }
        startDateInput = displayDate(vm.startDate)
    }

    private func commitEndDateInput() {
        if let parsed = parseTypedDate(endDateInput) {
            vm.endDate = parsed
        }
        endDateInput = displayDate(vm.endDate)
    }

    private func commitDayStartInput() {
        if let parsed = parseTypedTime(dayStartInput) {
            vm.dayStartTime = parsed
        }
        dayStartInput = formattedTime(vm.dayStartTime)
    }

    private func commitDayEndInput() {
        if let parsed = parseTypedTime(dayEndInput) {
            vm.dayEndTime = parsed
        }
        dayEndInput = formattedTime(vm.dayEndTime)
    }

    private func displayDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).year())
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func settingRow<Content: View>(_ title: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 10)
            control()
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    @ViewBuilder
    private func dateInput(
        text: Binding<String>,
        placeholder: String,
        showPicker: Binding<Bool>,
        pickerTitle: String,
        date: Binding<Date>,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            AutoSelectTextField(
                text: text,
                placeholder: placeholder,
                onCommit: onCommit
            )
            .frame(width: 158, height: 24, alignment: .trailing)

            Button {
                onCommit()
                showPicker.wrappedValue = true
            } label: {
                Image(systemName: "calendar")
            }
            .buttonStyle(.bordered)
            .popover(isPresented: showPicker, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker(pickerTitle, selection: date, displayedComponents: [.date])
                        .datePickerStyle(.graphical)
                    HStack {
                        Spacer()
                        Button("Done") { showPicker.wrappedValue = false }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
                .frame(width: 300)
            }
        }
    }

    @ViewBuilder
    private func calendarRow(_ calendar: Binding<CalendarChoice>) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: calendar.isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)

            Circle()
                .fill(calendar.wrappedValue.color)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.wrappedValue.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(calendar.wrappedValue.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.35))
        )
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.teal)
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
        }
    }
}

struct AutoSelectTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.placeholderString = placeholder
        textField.isBezeled = true
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.focusRingType = .none
        textField.alignment = .center
        textField.font = .systemFont(ofSize: 15, weight: .medium)
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.handleCommit)
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutoSelectTextField

        init(_ parent: AutoSelectTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            textField.currentEditor()?.selectAll(nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onCommit()
        }

        @objc func handleCommit() {
            parent.onCommit()
        }
    }
}

@main
struct AppleAvailabilityApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 540, height: 680)
        .windowResizability(.automatic)
    }
}
