import SwiftUI
import AppKit

/// The log as a terminal-like table in a white card: a toolbar to filter by text and module
/// and to copy or clear, then one line per record (time, module, message, level).
struct DebugLogsView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    /// The module shown, or every module when nil.
    @State private var module: String?

    /// How many of the most frequent modules get a chip of their own; the rest are in a menu.
    private static let chipCount = 4

    var body: some View {
        let entries = filteredEntries
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            // No fixed size: the page is not in a scroll view, and text that insists on its
            // full height at the window's narrowest set the window's minimum height to 2757pt.
            Text(DebugLogPresentation.scopeDescription)
                .font(AppTypography.interfaceCaption)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(3)

            VStack(spacing: 0) {
                toolbar(count: entries.count)
                SettingsDivider()
                if entries.isEmpty {
                    Text(appState.logs.entries.isEmpty ? "No records yet." : "No records match.")
                        .font(AppTypography.interfaceCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // A native list: it scrolls 500 rows cheaply and never asks the window for
                    // their height (a scroll view of them grew the window past the screen).
                    List(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        DebugLogRow(entry: entry, isStriped: index.isMultiple(of: 2))
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 28)
                    // The newest records are at the bottom; the table opens on them.
                    .defaultScrollAnchor(.bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous))
            .settingsCard()
        }
        .padding(.horizontal, AppSemanticLayout.settingsPageLeading)
        .padding(.top, AppSemanticLayout.settingsPageTop)
        .padding(.bottom, AppSpacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func toolbar(count: Int) -> some View {
        HStack(spacing: AppSpacing.small) {
            SettingsSearchField(text: $query, placeholder: "Filter logs…")
                .frame(maxWidth: 220)

            moduleChip("All", isSelected: module == nil) { module = nil }
            ForEach(frequentModules, id: \.self) { name in
                moduleChip(name, isSelected: module == name) { module = name }
            }
            if !otherModules.isEmpty {
                Menu {
                    ForEach(otherModules, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { module == name }, set: { _ in module = name }))
                    }
                } label: {
                    Text(otherModules.contains(module ?? "") ? module ?? "More" : "More")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(otherModules.contains(module ?? "") ? AppColors.sendGlyph : Color.primary.opacity(0.75))
                .padding(.horizontal, AppSpacing.small)
                .frame(height: 22)
                .background(Capsule().fill(otherModules.contains(module ?? "") ? AppColors.sendFill : Color.primary.opacity(0.05)))
                .fixedSize()
            }

            Spacer(minLength: AppSpacing.small)

            Button {
                copy(filteredEntries)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(GhostIconButtonStyle(size: 26, iconSize: 12))
            .help("Copy the records shown (\(count))")
            .accessibilityLabel("Copy")

            Button {
                appState.logs.clearDisplayed()
            } label: {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(GhostIconButtonStyle(size: 26, iconSize: 12))
            .help("Clear the list (the log file on disk keeps every record)")
            .accessibilityLabel("Clear")
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(height: 44)
    }

    private func moduleChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isSelected ? AppColors.sendGlyph : Color.primary.opacity(0.75))
                .padding(.horizontal, AppSpacing.small)
                .frame(height: 22)
                .background(Capsule().fill(isSelected ? AppColors.sendFill : Color.primary.opacity(0.05)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Modules by how often they appear in the records held now, most frequent first.
    private var modulesByFrequency: [String] {
        var counts: [String: Int] = [:]
        for entry in appState.logs.entries { counts[entry.category, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    private var frequentModules: [String] {
        Array(modulesByFrequency.prefix(Self.chipCount))
    }

    private var otherModules: [String] {
        modulesByFrequency.dropFirst(Self.chipCount).sorted()
    }

    private var filteredEntries: [DebugLogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return appState.logs.entries.filter { entry in
            (module == nil || entry.category == module)
                && (trimmed.isEmpty
                    || entry.message.localizedCaseInsensitiveContains(trimmed)
                    || entry.category.localizedCaseInsensitiveContains(trimmed))
        }
    }

    private func copy(_ entries: [DebugLogEntry]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let text = entries.map {
            "\(formatter.string(from: $0.timestamp)) [\($0.category)] \($0.level.rawValue.uppercased()) \($0.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One record on one line, in columns: time, module, message (cut to the line; the whole of it
/// in the tooltip), level.
private struct DebugLogRow: View {
    let entry: DebugLogEntry
    let isStriped: Bool

    private static let mono = Font.system(size: 12.5, design: .monospaced)

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Text(entry.timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .font(Self.mono)
                .foregroundStyle(Color.secondary.opacity(0.8))
                .frame(width: 68, alignment: .leading)

            Text(entry.category)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 5)
                .frame(width: 64, height: 18)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

            Text(entry.message)
                .font(Self.mono)
                .foregroundStyle(entry.level == .error ? AppColors.dangerText : Color.primary.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.message)
                .textSelection(.enabled)

            Text(entry.level.rawValue.uppercased())
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(entry.level == .error ? AppColors.dangerText : Color.secondary.opacity(0.7))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(height: 28)
        .background(isStriped ? Color.primary.opacity(0.02) : Color.clear)
        .contextMenu {
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.message, forType: .string)
            }
        }
    }
}
