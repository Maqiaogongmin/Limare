import SwiftUI

// MARK: - Floating Panel

/// On macOS 26 and later the sidebar is a glass panel floating on the canvas, inset from the
/// window's edges, rather than a column ruled off at the edge. The system draws its sidebar
/// column flush, with no way to turn its background off, so the canvas covers it and the
/// panel is drawn on top; the split view still sizes, collapses and restores the column.
/// Its 1pt divider stays visible in the gap beside the panel: the detail column cannot draw
/// past its own edge to cover it. Earlier systems keep the system sidebar.
struct FloatingSidebarPanel: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let panel = RoundedRectangle(cornerRadius: AppRadius.sidebarPanel, style: .continuous)
            content
                .scrollContentBackground(.hidden)
                .padding([.horizontal, .bottom], AppSpacing.sidebarPanelInset)
                .background {
                    Color.clear
                        .glassEffect(.regular, in: panel)
                        .padding(.horizontal, AppSpacing.sidebarPanelInset)
                        .padding(.bottom, AppSpacing.sidebarPanelInset)
                        .padding(.top, AppSpacing.sidebarPanelTopInset)
                        .ignoresSafeArea()
                }
                .background(AppColors.canvas.ignoresSafeArea())
        } else {
            content
        }
    }
}

// MARK: - Sidebar Row Container

struct SidebarRowContainer<Content: View, Actions: View>: View {
    let isSelected: Bool
    let isIndented: Bool
    let onSelect: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    @State private var isHovering = false
    @State private var actionsWidth: CGFloat = 0

    init(
        isSelected: Bool = false,
        isIndented: Bool = false,
        onSelect: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.isSelected = isSelected
        self.isIndented = isIndented
        self.onSelect = onSelect
        self.content = content
        self.actions = actions
    }

    @ViewBuilder
    var body: some View {
        if let onSelect {
            // A tap gesture alone gives VoiceOver and other accessibility clients no way to
            // open the row; the default action does the same as the tap.
            rowContent
                .onTapGesture { onSelect() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { onSelect() }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: AppSpacing.xSmall) {
                if isIndented {
                    Spacer().frame(width: AppSpacing.medium)
                }

                content()

                Spacer(minLength: 0)
            }
            .mask(
                GeometryReader { geo in
                    if isHovering && actionsWidth > 0 {
                        let clearWidth = actionsWidth + 4
                        let fadeWidth: CGFloat = 20
                        HStack(spacing: 0) {
                            Color.black
                                .frame(width: max(0, geo.size.width - clearWidth - fadeWidth))
                            LinearGradient(
                                colors: [Color.black, Color.clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: min(fadeWidth, max(0, geo.size.width - clearWidth)))
                            Color.clear
                                .frame(width: clearWidth)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Color.black
                    }
                }
            )

            if isHovering {
                HStack(spacing: 2) {
                    actions()
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ActionsWidthPreferenceKey.self, value: geo.size.width)
                    }
                )
                .transition(.opacity)
            }
        }
        .onPreferenceChange(ActionsWidthPreferenceKey.self) { newWidth in
            if newWidth > 0 {
                actionsWidth = newWidth
            }
        }
        .frame(minHeight: AppControlHeight.row)
        .padding(.vertical, AppSpacing.xxxSmall)
        .padding(.horizontal, AppSpacing.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.row)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.secondary.opacity(0.14)
        }
        if isHovering {
            return AppColors.surfaceInteractive
        }
        return Color.clear
    }
}

// MARK: - Sidebar Hover Icon Button

struct SidebarHoverIconButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isButtonHovered = false
    @FocusState private var isButtonFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isDestructive ? Color.red : ((isButtonHovered || isButtonFocused) ? Color.primary : Color.secondary))
                .frame(width: AppControlHeight.small, height: AppControlHeight.small)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small)
                        .fill((isButtonHovered || isButtonFocused) ? Color.secondary.opacity(0.18) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isButtonFocused)
        .onHover { isButtonHovered = $0 }
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}

// MARK: - Sidebar Rename Sheet

struct SidebarRenameSheet: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text(title)
                .font(AppTypography.interfaceHeadline)

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.interface)
                .frame(minWidth: 280)
                .onSubmit {
                    submit()
                }

            HStack(spacing: AppSpacing.small) {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppSpacing.standard)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

// MARK: - Sidebar Search Field

/// At rest this is a button, not a text field: AppKit gives a window's caret to its first text
/// field whenever the window becomes key with nothing focused (Schedules and Settings have no
/// composer to take it), and the search must only start when asked for, by a click or ⌘K.
struct SidebarSearchField: View {
    @Binding var text: String
    @State private var isActive = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isActive || !text.isEmpty {
                field
            } else {
                Button(action: activate) {
                    content(prompt: Text("Search").foregroundStyle(Color(nsColor: .placeholderTextColor)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
            }
        }
        // ⌘K reaches the search in either state, so it lives on a button that is always there.
        .background {
            Button("Search", action: activate)
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onChange(of: isFocused) { _, focused in
            if !focused && text.isEmpty { isActive = false }
        }
    }

    private var field: some View {
        // No bezel or focus ring of its own: the field's rounded edge shows focus.
        let textField = TextField("Search", text: $text)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .focused($isFocused)
            .onExitCommand {
                text = ""
                isFocused = false
            }
        return content(prompt: textField)
            // The field is inserted by this update; focus it once it is in the window.
            .onAppear { DispatchQueue.main.async { isFocused = true } }
    }

    private func activate() {
        // A field already shown takes focus here; a new one takes it as it appears.
        isActive = true
        isFocused = true
    }

    private func content(prompt: some View) -> some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            prompt
                .font(AppTypography.interfaceSubheadline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if text.isEmpty {
                // The shortcut as a key cap, apart from the prompt.
                Text("⌘K")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, AppSpacing.xxSmall)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .strokeBorder(AppColors.borderMuted, lineWidth: 1)
                    )
                    .fixedSize()
                    .accessibilityHidden(true)
            } else {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.row)
                .fill(AppColors.surfaceInteractive)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.row)
                .strokeBorder(Color.primary.opacity(isFocused ? 0.18 : 0.06), lineWidth: 1)
        )
    }
}

// MARK: - Sidebar Empty State

struct SidebarEmptyState: View {
    let message: LocalizedStringKey
    var isIndented: Bool = false

    var body: some View {
        Text(message)
            .font(AppTypography.interfaceCaption)
            .foregroundStyle(.secondary)
            .padding(.leading, isIndented ? AppSpacing.large : AppSpacing.small)
            .padding(.vertical, AppSpacing.xxSmall)
    }
}

// MARK: - Preference Keys

private struct ActionsWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
