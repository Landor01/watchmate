import SwiftUI
import SwiftData

struct ComingSoonView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.calendar) private var calendar
    @Query(sort: \Show.title) private var shows: [Show]
    @AppStorage("comingSoonCalendar") private var calendarMode = true
    @State private var selectedDate = Date()

    private var scheduledEntries: [ScheduledProgramme] {
        shows.filter { $0.isFollowing }.flatMap { show in
            show.episodes.compactMap { episode -> ScheduledProgramme? in
                guard let date = episode.firstAired, episode.watchedAt == nil, !episode.isSkipped,
                      store.settings.includeSpecials || episode.season > 0 else { return nil }
                return ScheduledProgramme(show: show, episode: episode, date: date)
            }
        }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
    }

    var body: some View {
        let entries = scheduledEntries
        let dates = Set(entries.map { calendar.startOfDay(for: $0.date) })
        let now = Date()
        let end = now.addingTimeInterval(30 * 86_400)
        let visibleEntries = entries.filter {
            calendarMode ? calendar.isDate($0.date, inSameDayAs: selectedDate) : ($0.date > now && $0.date <= end)
        }
        GeometryReader { geometry in
            // Use the current window's space so rotation and resizing update the layout.
            let usesColumns = geometry.size.width > geometry.size.height && geometry.size.width >= 600
            if calendarMode && usesColumns {
                HStack(spacing: 0) {
                    LandscapeCalendarPanel(
                        selectedDate: $selectedDate,
                        scheduledDates: dates
                    )
                    .frame(width: (geometry.size.width - 1) / 2)

                    Divider()

                    ThemedList {
                        ScheduledDateSection(entries: visibleEntries, selectedDate: selectedDate)
                        Section {
                            Text("Air dates can change and may differ from local streaming release dates.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .refreshable { await store.refresh() }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ThemedList {
                    ComingSoonAirDateSection()
                    if calendarMode {
                        Section {
                            ProgrammeCalendar(selectedDate: $selectedDate, scheduledDates: dates)
                        }
                        ScheduledDateSection(entries: visibleEntries, selectedDate: selectedDate)
                    } else {
                        Section("Next 30 days") {
                            ScheduledProgrammeRows(entries: visibleEntries, calendarMode: false)
                        }
                    }
                }
                .refreshable { await store.refresh() }
            }
        }
        .navigationTitle("Coming Soon")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button("Calendar", systemImage: "calendar") { calendarMode = true }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(calendarMode ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityAddTraits(calendarMode ? .isSelected : [])
                Button("List", systemImage: "list.bullet") { calendarMode = false }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(!calendarMode ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityAddTraits(!calendarMode ? .isSelected : [])
            }
        }
    }
}

private struct LandscapeCalendarPanel: View {
    @AppStorage("appTheme") private var themeValue = AppTheme.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedDate: Date
    let scheduledDates: Set<Date>

    var body: some View {
        let theme = AppTheme(rawValue: themeValue) ?? .system
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ProgrammeCalendar(
                    selectedDate: $selectedDate,
                    scheduledDates: scheduledDates,
                    availableHeight: max(0, geometry.size.height - 8)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    theme == .system
                        ? Color(uiColor: .secondarySystemGroupedBackground)
                        : theme.tileColor(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(theme.backgroundColor(for: colorScheme))
    }
}

private struct ComingSoonAirDateSection: View {

    var body: some View {
        Section {
            Text("Air dates can change and may differ from local streaming release dates.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ScheduledDateSection: View {
    let entries: [ScheduledProgramme]
    let selectedDate: Date

    var body: some View {
        Section {
            ScheduledProgrammeRows(entries: entries, calendarMode: true)
        } header: {
            Text(selectedDate, format: .dateTime.weekday(.wide).day().month(.wide).year())
        }
    }
}

private struct ScheduledProgramme: Identifiable {
    let show: Show
    let episode: Episode
    let date: Date
    var id: String { episode.key }
}

private struct ScheduledProgrammeRows: View {
    let entries: [ScheduledProgramme]
    let calendarMode: Bool

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                calendarMode ? "Nothing scheduled for this date" : "Nothing scheduled yet",
                systemImage: "calendar",
                description: Text("New air dates will appear when supplied by Trakt.")
            )
        } else {
            ForEach(entries) { entry in
                NavigationLink {
                    EpisodeDetailView(episode: entry.episode)
                } label: {
                    ShowRow(show: entry.show, episode: entry.episode, squareArtwork: true, showsAiredPrefix: true, squareArtworkSize: 96)
                }
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading]
                }
            }
        }
    }
}

private struct ProgrammeCalendar: View {
    @Environment(\.calendar) private var calendar
    @Binding var selectedDate: Date
    let scheduledDates: Set<Date>

    var availableHeight: CGFloat? = nil

    // Calendar arithmetic preserves local day boundaries across daylight-saving changes.
    private var days: [Date] {
        guard let month = calendar.dateInterval(of: .month, for: selectedDate),
              let range = calendar.range(of: .day, in: .month, for: selectedDate) else { return [] }
        let leading = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        let count = ((leading + range.count + 6) / 7) * 7
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0 - leading, to: month.start) }
    }

    var body: some View {
        let dates = days
        let compact = availableHeight != nil
        let headerHeight: CGFloat = compact ? 32 : 44
        // Reserve space for month controls, weekday labels, and Today, then fit every week.
        let reservedHeight: CGFloat = headerHeight + 28 + 44 + 4
        let weekCount = CGFloat(max(1, dates.count / 7))
        let rowHeight = availableHeight.map { height in
            min(44, max(1, (height - reservedHeight) / weekCount))
        } ?? 44
        VStack(spacing: compact ? 4 : 12) {
            HStack {
                Button { moveMonth(-1) } label: {
                    Image(systemName: "chevron.backward")
                        .frame(minWidth: 44, minHeight: headerHeight)
                }
                .accessibilityLabel("Previous month")
                Spacer(minLength: 0)
                Text(selectedDate, format: .dateTime.month(.wide).year())
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { moveMonth(1) } label: {
                    Image(systemName: "chevron.forward")
                        .frame(minWidth: 44, minHeight: headerHeight)
                }
                .accessibilityLabel("Next month")
            }
            Grid(horizontalSpacing: 0, verticalSpacing: compact ? 0 : 4) {
                GridRow {
                    ForEach(Array(dates.prefix(7)), id: \.self) { date in
                        Text(date, format: .dateTime.weekday(.narrow))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                }
                ForEach(dates.filter { calendar.component(.weekday, from: $0) == calendar.firstWeekday }, id: \.self) { weekStart in
                    GridRow {
                        ForEach(dates.filter { $0 >= weekStart && $0 < (calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart) }, id: \.self) { date in
                            CalendarDateButton(
                                date: date,
                                selected: calendar.isDate(date, inSameDayAs: selectedDate),
                                inMonth: calendar.isDate(date, equalTo: selectedDate, toGranularity: .month),
                                scheduled: scheduledDates.contains(calendar.startOfDay(for: date)),
                                rowHeight: rowHeight
                            ) {
                                selectedDate = date
                            }
                        }
                    }
                }
            }
            Button("Today") { selectedDate = Date() }
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
    }

    private func moveMonth(_ offset: Int) {
        guard let start = calendar.dateInterval(of: .month, for: selectedDate)?.start,
              let next = calendar.date(byAdding: .month, value: offset, to: start) else { return }
        selectedDate = next
    }
}

private struct CalendarDateButton: View {
    @Environment(\.themeAccent) private var themeAccent
    @Environment(\.calendar) private var calendar
    let date: Date
    let selected: Bool
    let inMonth: Bool
    let scheduled: Bool
    var rowHeight: CGFloat = 44
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: rowHeight < 44 ? 0 : 4) {
                Text(date, format: .dateTime.day())
                    .font(rowHeight < 44 ? .caption : .body)
                    .fontWeight(calendar.isDateInToday(date) ? .bold : .regular)
                Circle()
                    .fill(selected ? Color.white : themeAccent)
                    .frame(width: 5, height: 5)
                    .opacity(scheduled ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)
            .foregroundStyle(selected ? Color.white : (inMonth ? Color.primary : Color.secondary))
            .background(selected ? themeAccent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(scheduled ? "Programmes scheduled" : "No programmes scheduled")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
