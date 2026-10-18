import SwiftUI

// MARK: - Settings Page Container

public struct SettingsPage<Content: View>: View {
    public let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                content
            }
            .frame(maxWidth: AppSemanticLayout.settingsDetailContentMaxWidth, alignment: .leading)
            .padding(AppSemanticSpacing.settingsPageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Settings Row

public struct SettingsRow<Control: View>: View {
    public let title: String
    public let caption: String?
    public let control: Control

    public init(
        _ title: String,
        caption: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: AppSemanticSpacing.settingsRowControlGap) {
            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                Text(title)
                    .font(AppTypography.interfaceMedium)
                    .foregroundStyle(AppColors.textPrimary)

                if let caption {
                    Text(caption)
                        .font(AppTypography.interfaceCaption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }

            Spacer(minLength: AppSpacing.small)

            control
        }
        .padding(.vertical, AppSemanticSpacing.settingsRowVerticalPadding)
    }
}

// MARK: - Settings Section Card

public struct SettingsSection<Content: View, Trailing: View>: View {
    public let title: String?
    public let description: String?
    public let trailing: Trailing
    public let content: Content

    public init(
        title: String? = nil,
        description: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.trailing = trailing()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsRowGap) {
            if title != nil || description != nil || !(trailing is EmptyView) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                        if let title {
                            Text(title)
                                .font(AppTypography.interfaceHeadline)
                                .foregroundStyle(AppColors.textPrimary)
                        }
                        if let description {
                            Text(description)
                                .font(AppTypography.interfaceCaption)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, AppSpacing.xxSmall)
            }

            VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsFieldGap) {
                content
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .stroke(AppColors.borderMuted, lineWidth: 1)
            )
        }
    }
}

// MARK: - Form Field

public struct FormField<Content: View>: View {
    public let label: String
    public let caption: String?
    public let labelWidth: CGFloat?
    public let content: Content

    public init(
        _ label: String,
        caption: String? = nil,
        labelWidth: CGFloat? = 120,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.caption = caption
        self.labelWidth = labelWidth
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
            if let labelWidth {
                HStack(alignment: .center, spacing: AppSpacing.small) {
                    Text(label)
                        .font(AppTypography.interfaceMedium)
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(width: labelWidth, alignment: .leading)

                    content
                }
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text(label)
                        .font(AppTypography.interfaceMedium)
                        .foregroundStyle(AppColors.textPrimary)
                    content
                }
            }

            if let caption {
                Text(caption)
                    .font(AppTypography.interfaceCaption2)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.leading, labelWidth != nil ? (labelWidth! + AppSpacing.small) : 0)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Inline Status Banner

public enum InlineStatusKind {
    case info
    case success
    case warning
    case error

    public var color: Color {
        switch self {
        case .info: AppColors.statusInfo
        case .success: AppColors.statusSuccess
        case .warning: AppColors.statusWarning
        case .error: AppColors.statusError
        }
    }

    public var systemImage: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        }
    }
}

public struct InlineStatus: View {
    public let kind: InlineStatusKind
    public let message: String
    public var actionTitle: String? = nil
    public var onAction: (() -> Void)? = nil

    public init(
        kind: InlineStatusKind,
        message: String,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    public var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.small) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind.color)

            Text(message)
                .font(AppTypography.interfaceSubheadline)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)

            Spacer()

            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .background(kind.color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .stroke(kind.color.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Three-Level Error Presentation

public struct ThreeLevelErrorView: View {
    public let explanation: String
    public let recommendedAction: String?
    public let technicalDetails: String?
    public var onRetry: (() -> Void)? = nil
    public var retryTitle: String = "Retry"

    @State private var isTechnicalExpanded = false

    public init(
        explanation: String,
        recommendedAction: String? = nil,
        technicalDetails: String? = nil,
        onRetry: (() -> Void)? = nil,
        retryTitle: String = "Retry"
    ) {
        self.explanation = explanation
        self.recommendedAction = recommendedAction
        self.technicalDetails = technicalDetails
        self.onRetry = onRetry
        self.retryTitle = retryTitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            // Level 1: Human Explanation
            HStack(alignment: .top, spacing: AppSpacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.statusError)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(explanation)
                        .font(AppTypography.interfaceSemibold)
                        .foregroundStyle(AppColors.textPrimary)

                    // Level 2: Recommended Action
                    if let recommendedAction {
                        Text(recommendedAction)
                            .font(AppTypography.interfaceCaption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }

                Spacer()

                if let onRetry {
                    Button(retryTitle, action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            // Level 3: Optional Technical Details
            if let technicalDetails, !technicalDetails.isEmpty {
                DisclosureGroup(
                    isExpanded: $isTechnicalExpanded,
                    content: {
                        Text(technicalDetails)
                            .font(AppTypography.codeMeta)
                            .foregroundStyle(AppColors.textSecondary)
                            .textSelection(.enabled)
                            .padding(AppSpacing.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.surfaceSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                            .padding(.top, 4)
                    },
                    label: {
                        Text(isTechnicalExpanded ? "Hide Technical Details" : "Technical Details")
                            .font(AppTypography.interfaceCaption2.weight(.medium))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                )
            }
        }
        .padding(AppSpacing.medium)
        .background(AppColors.statusError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(AppColors.statusError.opacity(0.22), lineWidth: 1)
        )
    }
}

// MARK: - Collapsible Disclosure Section

public struct DisclosureSection<Content: View>: View {
    public let title: String
    public let summary: String?
    @Binding public var isExpanded: Bool
    public let content: Content

    public init(
        title: String,
        summary: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.summary = summary
        self._isExpanded = isExpanded
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppMotion.resolved(AppMotion.layout)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(AppTypography.interfaceSemibold)
                            .foregroundStyle(AppColors.textPrimary)
                        if let summary, !isExpanded {
                            Text(summary)
                                .font(AppTypography.interfaceCaption2)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, AppSpacing.medium)

                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsFieldGap) {
                    content
                }
                .padding(AppSpacing.medium)
            }
        }
        .background(AppColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(AppColors.borderMuted, lineWidth: 1)
        )
    }
}

// MARK: - Resource Row for Sidebar

public struct ResourceRow: View {
    public let title: String
    public let subtitle: String?
    public let statusColor: Color?
    public let isSelected: Bool

    public init(
        title: String,
        subtitle: String? = nil,
        statusColor: Color? = nil,
        isSelected: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.statusColor = statusColor
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.small) {
            if let statusColor {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTypography.interface.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle {
                    Text(subtitle)
                        .font(AppTypography.interfaceCaption2)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, AppSemanticSpacing.resourceListRowPaddingVertical)
        .padding(.horizontal, AppSemanticSpacing.resourceListRowPaddingHorizontal)
        .background(isSelected ? AppColors.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - Settings Search Field

public struct SettingsSearchField: View {
    @Binding public var text: String
    public var placeholder: String = "Search…"
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, placeholder: String = "Search…") {
        self._text = text
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(AppTypography.interfaceSubheadline)
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(AppColors.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .stroke(isFocused ? Color.accentColor.opacity(0.6) : AppColors.borderMuted, lineWidth: 1)
        )
    }
}
