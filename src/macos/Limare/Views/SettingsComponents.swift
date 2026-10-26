import SwiftUI

// MARK: - Settings Page Container

/// Every settings page's column: left-aligned at the same edge, at most
/// `settingsPageMaxWidth` wide, on the warm canvas. Lines fade as they scroll under the title bar.
public struct SettingsPage<Content: View>: View {
    public let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            SettingsColumn {
                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                    content
                }
            }
            .padding(.top, AppSemanticLayout.settingsPageTop)
            .padding(.bottom, AppSemanticLayout.settingsPageTop)
        }
        .settingsScrollEdgeFade()
    }
}

/// The settings pages' column without a scroll view: for a page's own header row (search and
/// actions above a list), so it lines up with the cards below it.
public struct SettingsColumn<Content: View>: View {
    public let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: AppSemanticLayout.settingsPageMaxWidth, alignment: .leading)
            .padding(.horizontal, AppSemanticLayout.settingsPageLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Content scrolled under the transparent title bar fades out instead of running under it.
    /// Apply it directly to the `ScrollView`, so it receives the scroll geometry.
    func settingsScrollEdgeFade() -> some View {
        modifier(SettingsScrollEdgeFade())
    }

    /// A white card on the canvas: settings sections, master lists' selected rows, the log table.
    func settingsCard(cornerRadius: CGFloat = AppRadius.settingsCard) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppColors.workSurface)
                .shadow(color: .black.opacity(0.025), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AppColors.hairline, lineWidth: 1)
        )
    }
}

/// The fade appears only once content has scrolled past the top edge; at rest it masks nothing,
/// so a page whose first row sits right at the top (the archive list) is not covered.
struct SettingsScrollEdgeFade: ViewModifier {
    @State private var isScrolled = false

    /// Whether the content's top edge has moved above the visible area.
    static func isScrolled(contentOffsetY: CGFloat, contentInsetTop: CGFloat) -> Bool {
        contentOffsetY + contentInsetTop > 0.5
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                Self.isScrolled(contentOffsetY: geometry.contentOffset.y,
                                contentInsetTop: geometry.contentInsets.top)
            } action: { _, scrolled in
                isScrolled = scrolled
            }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [isScrolled ? .clear : .black, .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: AppLayout.scrollEdgeFade)
                    Color.black
                }
                .animation(.easeOut(duration: 0.15), value: isScrolled)
            )
    }
}

extension View {
    /// A text field as a faint well, borderless, like the page's search fields.
    func settingsFieldWell() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, AppSpacing.small)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }
}

/// The rule between rows inside a settings card: faint, and set in from the card's edges.
public struct SettingsDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Settings Controls

/// The settings pages' main action: charcoal with white text (near-white with dark text in
/// dark mode). Disabled, it is an outline with quiet text.
public struct CharcoalProminentButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        CharcoalProminentBody(configuration: configuration)
    }

    private struct CharcoalProminentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
            configuration.label
                .font(.system(size: controlSize == .small || controlSize == .mini ? 12 : 13, weight: .medium))
                .foregroundStyle(isEnabled ? AppColors.sendGlyph : Color.secondary)
                .padding(.horizontal, controlSize == .small || controlSize == .mini ? 10 : 12)
                .frame(minHeight: controlSize == .small || controlSize == .mini ? 22 : 26)
                .background(shape.fill(isEnabled ? AppColors.sendFill : Color.clear))
                .overlay(shape.strokeBorder(isEnabled ? Color.clear : Color.primary.opacity(0.12), lineWidth: 1))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(shape)
        }
    }
}

/// A light outlined button: secondary actions and links set as buttons.
public struct SettingsOutlineButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
        return configuration.label
            .font(.system(size: 12))
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(shape.fill(configuration.isPressed ? Color.primary.opacity(0.06) : AppColors.workSurface))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(shape)
    }
}

public extension ButtonStyle where Self == CharcoalProminentButtonStyle {
    static var charcoalProminent: CharcoalProminentButtonStyle { CharcoalProminentButtonStyle() }
}

public extension ButtonStyle where Self == SettingsOutlineButtonStyle {
    static var settingsOutline: SettingsOutlineButtonStyle { SettingsOutlineButtonStyle() }
}

/// A checkbox that reads as one whether on or off: charcoal and ticked when on, a hollow white
/// box when off (a filled grey box looked disabled).
public struct CharcoalCheckboxToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        CharcoalCheckboxBody(configuration: configuration)
    }

    private struct CharcoalCheckboxBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let box = RoundedRectangle(cornerRadius: 4, style: .continuous)
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    ZStack {
                        box.fill(configuration.isOn ? AppColors.sendFill : AppColors.workSurface)
                        box.strokeBorder(configuration.isOn ? Color.clear : Color.primary.opacity(0.22), lineWidth: 1.5)
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppColors.sendGlyph)
                        }
                    }
                    .frame(width: 14, height: 14)
                    configuration.label
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

public extension ToggleStyle where Self == CharcoalCheckboxToggleStyle {
    static var charcoalCheckbox: CharcoalCheckboxToggleStyle { CharcoalCheckboxToggleStyle() }
}

/// A segmented choice whose selected segment is charcoal, not the system blue.
public struct SettingsSegmentedPicker<Value: Hashable>: View {
    @Binding public var selection: Value
    public let options: [(value: Value, title: String)]

    public init(selection: Binding<Value>, options: [(value: Value, title: String)]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? AppColors.sendGlyph : Color.primary.opacity(0.75))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? AppColors.sendFill : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.row + 1, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .animation(AppMotion.resolved(AppMotion.quick), value: selection)
    }
}

/// A radio button's mark: a charcoal disc with a white centre when chosen, a hollow ring when not.
public struct SettingsRadioMark: View {
    public let isSelected: Bool

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public var body: some View {
        ZStack {
            Circle().fill(isSelected ? AppColors.sendFill : AppColors.workSurface)
            Circle().strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.22), lineWidth: 1.5)
            if isSelected {
                Circle().fill(AppColors.sendGlyph).frame(width: 6, height: 6)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// A small status or kind label. Neutral slate for kinds (Recommended, Project, Chat…); green
/// only for a healthy state (Connected, Trusted); red only for danger.
public struct SettingsBadge: View {
    public enum Tone {
        case neutral
        case positive
        case danger
    }

    public let title: String
    public let tone: Tone

    public init(_ title: String, tone: Tone = .neutral) {
        self.title = title
        self.tone = tone
    }

    /// A status shown as a badge: success green, error red, everything else neutral.
    public init(_ title: String, status: InlineStatusKind) {
        self.title = title
        self.tone = switch status {
        case .success: .positive
        case .error: .danger
        case .info, .warning: .neutral
        }
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
            .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .neutral: Color.primary.opacity(0.75)
        case .positive: AppColors.positiveText
        case .danger: AppColors.dangerText
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Color.primary.opacity(0.06)
        case .positive: Color(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255).opacity(0.10)
        case .danger: Color(red: 0xDC / 255, green: 0x26 / 255, blue: 0x26 / 255).opacity(0.10)
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
            .padding(.horizontal, AppSpacing.standard)
            .padding(.vertical, AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard()
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
        case .info: AppColors.textSecondary
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
                        .buttonStyle(.charcoalProminent)
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
                SettingsDivider()
                    .padding(.horizontal, AppSpacing.standard)

                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsFieldGap) {
                    content
                }
                .padding(AppSpacing.medium)
            }
        }
        .settingsCard()
    }
}

// MARK: - Master List (two-column settings pages)

/// The list column of a two-column settings page (Providers, Model Groups): a fixed width on
/// the canvas, its header row (actions, not a second page title) above rows 4pt apart, no
/// rules between them.
public struct SettingsMasterList<Header: View, Content: View>: View {
    public let header: Header
    public let content: Content

    public init(@ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.header = header()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            header
                .padding(.horizontal, AppSpacing.medium)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    content
                }
                .padding(.horizontal, AppSpacing.small)
                .padding(.bottom, AppSpacing.medium)
            }
            .settingsScrollEdgeFade()
        }
        .padding(.top, AppSemanticLayout.settingsPageTop - AppSpacing.small)
        .frame(width: AppSemanticLayout.settingsMasterListWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A row of a master list: the selected one a white card lifted off the canvas, the others
/// bare with a faint tint under the pointer.
public struct SettingsMasterRow<Content: View>: View {
    public let isSelected: Bool
    public let onSelect: () -> Void
    public let content: Content

    @State private var isHovering = false

    public init(isSelected: Bool, onSelect: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    Color.clear.settingsCard(cornerRadius: AppRadius.control)
                } else {
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture(perform: onSelect)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onSelect() }
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
        // Selection is drawn by the row it sits in (`SettingsMasterRow`).
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
        // A borderless field set into the page, as the Files filter is.
        .padding(.horizontal, AppSpacing.small)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isFocused ? 0.06 : 0.04))
        )
    }
}
