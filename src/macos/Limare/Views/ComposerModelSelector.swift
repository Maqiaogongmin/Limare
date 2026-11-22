import SwiftUI
import AppKit

struct ComposerModelSelector: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage("limare.composer.recentDirectModels") private var recentDirectModelIDs = ""
    @Binding var isShowingModelBrowser: Bool

    private var selectableGroups: [ModelGroup] {
        ModelChoiceCatalog.selectableGroups(modelGroups: appState.modelGroups, providers: appState.providers.providers)
    }

    private var visibleModelEntries: [ModelPickerEntry] {
        ModelChoiceCatalog.visibleModelEntries(providers: appState.providers.providers, current: currentModelSource)
    }

    private func recentEntries(from entries: [ModelPickerEntry]) -> [ModelPickerEntry] {
        recentDirectModelIDs.split(separator: "\n").prefix(5).compactMap { id in
            entries.first(where: { $0.id == id })
        }
    }

    private var currentModelSource: ConversationModelSource? {
        ModelChoiceCatalog.currentModelSource(conversation: window.conversation,
                                              modelGroups: appState.modelGroups, providers: appState.providers)
    }

    var body: some View {
        // Its full title when the composer has room, else as wide as the room: a fixed width
        // made a long model name push the composer past a narrow chat column.
        // A group shows the model it would use now ("chat · DeepSeek V4.1 Flash"). Short of room
        // the group's name goes first, then the icon and the chevron: the model is what the
        // user needs to read, and it truncates only when nothing else is left to give up.
        Button {
            isShowingModelBrowser = true
        } label: {
            ViewThatFits(in: .horizontal) {
                modelLabel(compactModelLabel).fixedSize(horizontal: true, vertical: false)
                modelLabel(modelName).fixedSize(horizontal: true, vertical: false)
                modelLabel(modelName, showsIcon: false).fixedSize(horizontal: true, vertical: false)
                modelLabel(modelName, showsIcon: false, showsChevron: false).fixedSize(horizontal: true, vertical: false)
                modelLabel(modelName, showsIcon: false, showsChevron: false, truncates: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.modelSelector")
        .disabled(window.chat.isStreaming)
        .help(modelHelp)
        .accessibilityLabel(activeModelLabel)
        .popover(isPresented: $isShowingModelBrowser, arrowEdge: .top) {
            let entries = visibleModelEntries
            ComposerModelBrowser(
                groups: selectableGroups,
                groupLabel: modelGroupLabel,
                recentEntries: recentEntries(from: entries),
                entries: entries,
                selectedSource: currentModelSource,
                onSelect: { source in
                    isShowingModelBrowser = false
                    switch source {
                    case .group(let groupID): selectGroup(groupID)
                    case .direct(let providerID, let modelID):
                        selectDirectModel(providerID: providerID, modelID: modelID)
                    }
                },
                onConfigure: {
                    isShowingModelBrowser = false
                    window.screen = .settingsProviders
                },
                onClose: { isShowingModelBrowser = false }
            )
        }
    }

    private func modelLabel(_ label: String, showsIcon: Bool = true, showsChevron: Bool = true, truncates: Bool = false) -> some View {
        HStack(spacing: AppSpacing.xxSmall) {
            if showsIcon {
                Image(systemName: iconName)
                    .font(.system(size: 11))
            }
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: truncates ? nil : AppLayout.composerModelLabelMaximumWidth, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.7)
            }
        }
        .composerPill()
    }

    private var iconName: String {
        if case .group = currentModelSource {
            return "square.stack.3d.up"
        }
        return "cpu"
    }

    private var activeModelLabel: String {
        ModelChoiceCatalog.label(for: currentModelSource, modelGroups: appState.modelGroups, providers: appState.providers.providers)
    }

    /// The group or model name alone.
    private var sourceName: String {
        ModelChoiceCatalog.shortLabel(for: currentModelSource, modelGroups: appState.modelGroups, providers: appState.providers.providers)
    }

    private var groupSummary: (short: String, long: String)? {
        guard case .group(let groupID) = currentModelSource else { return nil }
        return ModelChoiceCatalog.groupModelSummary(groupID: groupID, modelGroups: appState.modelGroups,
                                                    providers: appState.providers.providers)
    }

    /// The model itself: a group's current model, or the direct model's name.
    private var modelName: String {
        groupSummary?.short ?? sourceName
    }

    private var compactModelLabel: String {
        guard let summary = groupSummary else { return sourceName }
        return "\(sourceName) · \(summary.short)"
    }

    private var modelHelp: String {
        groupSummary?.long ?? activeModelLabel
    }

    private func selectGroup(_ groupID: String) {
        if let activeID = window.conversationID {
            appState.conversations.setConversationModelSource(id: activeID, source: .group(groupID: groupID))
        }
    }

    private func modelGroupLabel(_ group: ModelGroup) -> String {
        var uses: [String] = []
        if appState.modelGroups.defaultPrimaryGroupId == group.id { uses.append(String(localized: "Chat default")) }
        if appState.modelGroups.defaultSubGroupId == group.id { uses.append(String(localized: "Helper")) }
        if appState.modelGroups.visionGroupId == group.id { uses.append(String(localized: "Images")) }
        if appState.modelGroups.voiceInputGroupId == group.id { uses.append(String(localized: "Voice input")) }
        if appState.modelGroups.voiceOutputGroupId == group.id { uses.append(String(localized: "Voice output")) }
        guard !uses.isEmpty else { return group.name }
        return "\(group.name) · \(uses.joined(separator: ", "))"
    }

    private func selectDirectModel(providerID: UUID, modelID: String) {
        guard let activeID = window.conversationID else { return }
        appState.conversations.setConversationModelSource(id: activeID, source: .direct(providerID: providerID, modelID: modelID))
        let selectedID = ModelGroup.makeEntryId(providerID: providerID, modelID: modelID)
        let otherIDs = recentDirectModelIDs.split(separator: "\n").map(String.init).filter { $0 != selectedID }
        recentDirectModelIDs = ([selectedID] + otherIDs).prefix(5).joined(separator: "\n")
    }
}

private struct ComposerModelBrowser: View {
    private struct Choice: Identifiable {
        let id: String
        let title: String
        let source: ConversationModelSource?
        var providerID: UUID? = nil
    }

    private struct FilteredCatalog {
        var groupChoices: [Choice] = []
        var recentChoices: [Choice] = []
        var providerSections: [(id: UUID, name: String, choices: [Choice])] = []
        var choices: [Choice] = []
    }

    @State private var searchText = ""
    @State private var highlightedID: String?
    @State private var lastMouseLocation = NSEvent.mouseLocation
    @State private var appeared = false
    @State private var expandedProviders: Set<UUID> = []
    @State private var catalog = FilteredCatalog()
    @FocusState private var isSearchFocused: Bool

    let groups: [ModelGroup]
    let groupLabel: (ModelGroup) -> String
    let recentEntries: [ModelPickerEntry]
    let entries: [ModelPickerEntry]
    let selectedSource: ConversationModelSource?
    let onSelect: (ConversationModelSource) -> Void
    let onConfigure: () -> Void
    let onClose: () -> Void

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func modelChoice(_ entry: ModelPickerEntry, prefix: String, showsProvider: Bool) -> Choice {
        Choice(id: "\(prefix):\(entry.id)",
               title: showsProvider ? "\(entry.providerName) / \(entry.model.displayName)" : entry.model.displayName,
               source: .direct(providerID: entry.providerID, modelID: entry.model.id))
    }

    private func isProviderExpanded(_ id: UUID) -> Bool {
        !query.isEmpty || expandedProviders.contains(id)
    }

    private func rebuildCatalog() {
        let trimmed = query
        func matches(_ text: String) -> Bool {
            trimmed.isEmpty || text.localizedCaseInsensitiveContains(trimmed)
        }

        let groupChoices = groups.filter { matches(groupLabel($0)) }.map {
            Choice(id: "group:\($0.id)", title: groupLabel($0), source: .group(groupID: $0.id))
        }

        let recentChoices = recentEntries
            .filter { matches($0.providerName) || matches($0.model.displayName) || matches($0.model.id) }
            .map { modelChoice($0, prefix: "recent", showsProvider: true) }

        let filteredEntries = entries.filter {
            matches($0.providerName) || matches($0.model.displayName) || matches($0.model.id)
        }

        var providerSections: [(id: UUID, name: String, choices: [Choice])] = []
        for entry in filteredEntries {
            if let index = providerSections.firstIndex(where: { $0.id == entry.providerID }) {
                providerSections[index].choices.append(modelChoice(entry, prefix: "provider", showsProvider: false))
            } else {
                providerSections.append((entry.providerID, entry.providerName,
                                         [modelChoice(entry, prefix: "provider", showsProvider: false)]))
            }
        }

        let choices = groupChoices + recentChoices + providerSections.flatMap { section in
            if !trimmed.isEmpty { return section.choices }
            let provider = Choice(id: "heading:\(section.id)", title: section.name,
                                  source: nil, providerID: section.id)
            return [provider] + (expandedProviders.contains(section.id) ? section.choices : [])
        }

        catalog = FilteredCatalog(
            groupChoices: groupChoices,
            recentChoices: recentChoices,
            providerSections: providerSections,
            choices: choices
        )
    }

    private func activate(_ choice: Choice) {
        if let source = choice.source {
            choose(source)
        } else if let id = choice.providerID, query.isEmpty {
            if expandedProviders.contains(id) { expandedProviders.remove(id) }
            else { expandedProviders.insert(id) }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search providers or models", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .onKeyPress { press in
                            switch press.key {
                            case .downArrow:
                                moveHighlight(1)
                                if let highlightedID { proxy.scrollTo(highlightedID, anchor: .center) }
                                return .handled
                            case .upArrow:
                                moveHighlight(-1)
                                if let highlightedID { proxy.scrollTo(highlightedID, anchor: .center) }
                                return .handled
                            case .return:
                                if let choice = catalog.choices.first(where: { $0.id == highlightedID }) ?? catalog.choices.first {
                                    activate(choice)
                                    return .handled
                                }
                                return .ignored
                            case .escape: close(); return .handled
                            default: return .ignored
                            }
                        }
                }
                .padding(12)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !catalog.groupChoices.isEmpty {
                            sectionTitle("Model Groups")
                            ForEach(catalog.groupChoices) { choiceRow($0) }
                        }
                        if !catalog.recentChoices.isEmpty {
                            sectionTitle("Recent Models")
                            ForEach(catalog.recentChoices) { choiceRow($0) }
                        }
                        if !catalog.providerSections.isEmpty {
                            sectionTitle("Providers & Models")
                            ForEach(catalog.providerSections, id: \.id) { section in
                                if query.isEmpty {
                                    choiceRow(Choice(id: "heading:\(section.id)", title: section.name,
                                                     source: nil, providerID: section.id))
                                } else {
                                    Text(section.name).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 2)
                                }
                                if isProviderExpanded(section.id) {
                                    ForEach(section.choices) { choice in
                                        choiceRow(choice).padding(.leading, 14)
                                    }
                                }
                            }
                        }
                        if catalog.choices.isEmpty {
                            Group {
                                if query.isEmpty { Text("No Models Available") }
                                else { Text("No results for \"\(query)\"") }
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                        }
                    }
                    .padding(6)
                }
                Divider()
                Button("Configure Providers…", action: onConfigure)
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(width: 360, height: 440)
            .opacity(appeared ? 1 : 0.94)
            .scaleEffect(appeared ? 1 : 0.985, anchor: .bottomTrailing)
            .onAppear {
                lastMouseLocation = NSEvent.mouseLocation
                rebuildCatalog()
                highlightedID = catalog.choices.first(where: { $0.source != nil && $0.source == selectedSource })?.id ?? catalog.choices.first?.id
                withAnimation(AppMotion.resolved(AppMotion.quick)) { appeared = true }
                isSearchFocused = true
            }
            .onChange(of: searchText) { _, _ in
                rebuildCatalog()
                highlightedID = catalog.choices.first?.id
            }
            .onChange(of: expandedProviders) { _, _ in
                rebuildCatalog()
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
    }

    private func choiceRow(_ choice: Choice) -> some View {
        Button { activate(choice) } label: {
            HStack {
                Text(choice.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let providerID = choice.providerID {
                    Image(systemName: isProviderExpanded(providerID) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                } else if choice.source == selectedSource {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(highlightedID == choice.id ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            let location = NSEvent.mouseLocation
            guard location != lastMouseLocation else { return }
            lastMouseLocation = location
            highlightedID = choice.id
        }
        .id(choice.id)
    }

    private func moveHighlight(_ delta: Int) {
        let all = catalog.choices
        guard !all.isEmpty else { return }
        let index = all.firstIndex(where: { $0.id == highlightedID }) ?? (delta > 0 ? -1 : 0)
        highlightedID = all[(index + delta + all.count) % all.count].id
    }

    private func choose(_ source: ConversationModelSource) {
        onSelect(source)
    }

    private func close() {
        onClose()
    }
}
