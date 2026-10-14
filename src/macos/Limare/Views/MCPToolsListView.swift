import SwiftUI

struct MCPToolsListView: View {
    let serverID: String
    let tools: [MCPTool]
    var onBack: (() -> Void)? = nil

    @State private var searchText = ""
    @State private var expandedToolIDs: Set<String> = []

    private var filteredTools: [MCPTool] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return tools }
        return tools.filter { tool in
            tool.name.localizedCaseInsensitiveContains(query)
                || tool.description.localizedCaseInsensitiveContains(query)
                || tool.exposedName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            toolList
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AppSpacing.small) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Connection")
                            .font(.subheadline.weight(.medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Divider()
                    .frame(height: 14)
            }

            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                Text("Tools: \(serverID)")
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                Text("\(tools.count) \(tools.count == 1 ? "tool" : "tools") provided by this connection")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
        }
        .padding(AppSpacing.medium)
    }

    private var searchBar: some View {
        HStack {
            SettingsSearchField(text: $searchText, placeholder: "Search tools…")
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    @ViewBuilder
    private var toolList: some View {
        if tools.isEmpty {
            ContentUnavailableView(
                "No Tools Discovered",
                systemImage: "wrench.and.screwdriver",
                description: Text("This server did not report any available tools.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if filteredTools.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsRowGap) {
                    ForEach(filteredTools) { tool in
                        toolCard(tool)
                    }
                }
                .padding(AppSpacing.medium)
            }
        }
    }

    private func toolCard(_ tool: MCPTool) -> some View {
        let isExpanded = expandedToolIDs.contains(tool.id)
        return VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                    HStack(spacing: AppSpacing.xSmall) {
                        Text(tool.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppColors.textPrimary)

                        Text(tool.exposedName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AppColors.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AppColors.surfaceSecondary)
                            .clipShape(Capsule())
                    }

                    if !tool.description.isEmpty {
                        Text(tool.description)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: AppSpacing.small)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded {
                            expandedToolIDs.remove(tool.id)
                        } else {
                            expandedToolIDs.insert(tool.id)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Hide Schema" : "View Schema")
                            .font(.caption2.weight(.medium))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input Schema:")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                    Text(schemaJSON(for: tool.inputSchema))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(AppSpacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                }
                .padding(.top, 4)
            }
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(AppColors.borderMuted, lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack {
            Text("\(filteredTools.count) matching of \(tools.count) total")
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
            if let onBack {
                Button("Back") {
                    onBack()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .background(AppColors.surfaceSecondary.opacity(0.4))
    }

    private func schemaJSON(for anyCodable: AnyCodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(anyCodable),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
