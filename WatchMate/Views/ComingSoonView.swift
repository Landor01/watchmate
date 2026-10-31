import SwiftUI
import SwiftData

struct ComingSoonView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.calendar) private var calendar
    @Query(Show.withEpisodes) private var shows: [Show]
    @AppStorage("comingSoonCalendar") private var calendarMode = true
    @State private var selectedDate = AppStoreScreenshotMode.calendarDate

    @State private var sharedCatalogue = SharedDiscoveryCatalogue()

    private var scheduledEntries: [ScheduledProgramme] {
        let personal = shows.filter {
            $0.isFollowing && (!store.sharedShows.showIDs.contains($0.traktID) || store.sharedShows.personalShowIDs.contains($0.traktID))
        }.flatMap { show in
            show.episodes.compactMap { episode -> ScheduledProgramme? in
                guard let date = episode.firstAired, episode.watchedAt == nil, !episode.isSkipped,
                      store.settings.includeSpecials || episode.season > 0 else { return nil }
                return ScheduledProgramme(show: show, episode: episode, date: AirDates.day(date))
            }
        }
        let sharedEntries = SharedDiscoveryEntry.entries(lists: store.sharedShows.lists, catalogues: sharedCatalogue.episodes,
                                                         includeSpecials: store.settings.includeSpecials)
        let shared = SharedDiscoveryEntry.scheduled(sharedEntries)
            .compactMap { entry -> ScheduledProgramme? in
                guard !entry.watched, !entry.skipped, let date = entry.date else { return nil }
                return ScheduledProgramme(shared: entry, date: date)
            }
        return (personal + shared).sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
    }

    var body: some View {
        let entries = scheduledEntries
        let dates = Set(entries.map { calendar.startOfDay(for: $0.date) })
        let now = Date()
        let end = calendar.date(byAdding: .day, value: 30, to: calendar.startOfDay(for: now)) ?? now
        let visibleEntries = entries.filter {
            calendarMode ? calendar.isDate($0.date, inSameDayAs: selectedDate) : (!AirDates.hasAired($0.date, now: now) && $0.date <= end)
        }
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let viewportWidth = geometry.size.width + insets.leading + insets.trailing
            let viewportHeight = geometry.size.height + insets.top + insets.bottom
            // Keep seven 44-point date targets and the calendar's horizontal padding.
            let minimumCalendarWidth: CGFloat = 7 * 44 + 48
            let minimumListWidth: CGFloat = 220
            let usesColumns = viewportWidth > viewportHeight
                && geometry.size.width >= minimumCalendarWidth + minimumListWidth + 1
            if calendarMode && usesColumns {
                // Centre the divider on roomy displays; give the calendar enough
                // space for its date buttons on smaller landscape phones.
                let centredCalendarWidth = (geometry.size.width - 1 + insets.trailing - insets.leading) / 2
                let calendarWidth = min(
                    max(centredCalendarWidth, minimumCalendarWidth),
                    geometry.size.width - minimumListWidth - 1
                )
                let listWidth = geometry.size.width - 1 - calendarWidth
                HStack(spacing: 0) {
                    LandscapeCalendarPanel(
                        selectedDate: $selectedDate,
                        scheduledDates: dates
                    )
                    .frame(width: calendarWidth)

                    Divider()
                        .frame(width: 1)

                    ThemedList {
                        if sharedCatalogue.loading { ProgressView("Loading shared programmes…") }
                        if let message = sharedCatalogue.message { Text(message).foregroundStyle(.secondary) }
                        ScheduledDateSection(entries: visibleEntries, selectedDate: selectedDate)
                    }
                    .listStyle(.insetGrouped)
                    .contentMargins(.leading, 12, for: .scrollContent)
                    // Keep the entire rounded row clear of the trailing toolbar.
                    .contentMargins(.trailing, 12 + insets.trailing, for: .scrollContent)
                    .refreshable {
                        await store.refresh(showIDs: Set(shows.filter { $0.isFollowing && $0.seriesStatus != "Ended" && $0.seriesStatus != "Canceled" }.map(\.traktID)))
                        await store.refreshSharedShows()
                        await sharedCatalogue.load(store: store, shows: shows, forceRefresh: true)
                    }
                    .frame(width: listWidth)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                ThemedList {
                    if sharedCatalogue.loading { ProgressView("Loading shared programmes…") }
                    if let message = sharedCatalogue.message { Text(message).foregroundStyle(.secondary) }
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
                .refreshable {
                    await store.refresh(showIDs: Set(shows.filter { $0.isFollowing && $0.seriesStatus != "Ended" && $0.seriesStatus != "Canceled" }.map(\.traktID)))
                    await store.refreshSharedShows()
                    await sharedCatalogue.load(store: store, shows: shows, forceRefresh: true)
                }
            }
        }
        .task(id: "\(store.sharedShows.showIDs.sorted()):\(store.catalogueRevision)") { await sharedCatalogue.load(store: store, shows: shows) }
        .navigationTitle("Coming Soon")
        .navigationBarTitleDisplayMode(.inline)
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
        ScrollView {
            ProgrammeCalendar(
                selectedDate: $selectedDate,
                scheduledDates: scheduledDates
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(theme.backgroundColor(for: colorScheme))
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
    var show: Show?
    var episode: Episode?
    var shared: SharedDiscoveryEntry?
    let date: Date
    var id: String { shared?.id ?? episode?.key ?? "" }
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
                VStack(alignment: .leading) {
                    if let shared = entry.shared {
                        SharedDiscoveryRow(entry: shared)
                    } else if let show = entry.show, let episode = entry.episode {
                        NavigationLink {
                            EpisodeDetailView(episode: episode)
                        } label: {
                            ShowRow(show: show, episode: episode, squareArtwork: true, showsAiredPrefix: true, squareArtworkSize: 96)
                        }
                    }
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
        VStack(spacing: 12) {
            HStack {
                Button { moveMonth(-1) } label: {
                    Image(systemName: "chevron.backward")
                        .frame(minWidth: 44, minHeight: 44)
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
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Next month")
            }
            Grid(horizontalSpacing: 0, verticalSpacing: 4) {
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
                                scheduled: scheduledDates.contains(calendar.startOfDay(for: date))
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
    @Environment(\.colorScheme) private var colorScheme
    let date: Date
    let selected: Bool
    let inMonth: Bool
    let scheduled: Bool
    let select: () -> Void

    var body: some View {
        let selectedForeground: Color = colorScheme == .dark ? .black : .white
        Button(action: select) {
            VStack(spacing: 4) {
                Text(date, format: .dateTime.day())
                    .font(.body)
                    .fontWeight(calendar.isDateInToday(date) ? .bold : .regular)
                Circle()
                    .fill(selected ? selectedForeground : themeAccent)
                    .frame(width: 5, height: 5)
                    .opacity(scheduled ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(selected ? selectedForeground : (inMonth ? Color.primary : Color.secondary))
            .background(selected ? themeAccent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(scheduled ? "Programmes scheduled" : "No programmes scheduled")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if DEBUG

#Preview("Coming Soon") {
    PreviewHost { data in
        NavigationStack { ComingSoonView() }
    }
}

#Preview("Calendar") {
    PreviewHost { data in
        ProgrammeCalendar(selectedDate: .constant(DemoLibrary.calendarDate), scheduledDates: [DemoLibrary.calendarDate]).padding()
    }
}

#Preview("Landscape calendar") {
    PreviewHost { data in
        LandscapeCalendarPanel(selectedDate: .constant(DemoLibrary.calendarDate), scheduledDates: [DemoLibrary.calendarDate])
    }
}

#Preview("Calendar date") {
    PreviewHost { data in
        CalendarDateButton(date: DemoLibrary.calendarDate, selected: true, inMonth: true, scheduled: true, select: {})
    }
}

#Preview("Scheduled date") {
    PreviewHost { data in
        List { ScheduledDateSection(entries: [ScheduledProgramme(show: data.show, episode: data.episode, date: DemoLibrary.calendarDate)], selectedDate: DemoLibrary.calendarDate) }
    }
}

#Preview("Scheduled rows") {
    PreviewHost { data in
        List { ScheduledProgrammeRows(entries: [ScheduledProgramme(show: data.show, episode: data.episode, date: DemoLibrary.calendarDate)], calendarMode: true) }
    }
}
#endif
