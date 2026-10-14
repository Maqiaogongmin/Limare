import SwiftUI

/// A column of ticks along the transcript's leading edge, one per user message. Ticks near the
/// pointer grow, the hovered one previews its message, and a click jumps the transcript to it.
struct UserMessageNavigator: View {
    let entries: [UserMessageNavigatorModel.Entry]
    let activeID: UUID?
    let availableHeight: CGFloat
    let onSelect: (UUID) -> Void

    @State private var pointerY: CGFloat?

    private let restingTickWidth: CGFloat = 10
    private let activeTickWidth: CGFloat = 18
    private let proximityGrowth: CGFloat = 12
    private let hitWidth: CGFloat = 36

    private var pitch: CGFloat {
        UserMessageNavigatorModel.tickPitch(entryCount: entries.count, availableHeight: availableHeight)
    }

    private var hoveredIndex: Int? {
        guard let pointerY else { return nil }
        return UserMessageNavigatorModel.index(atY: pointerY, pitch: pitch, entryCount: entries.count)
    }

    var body: some View {
        let pitch = pitch
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                tick(for: entry, index: index, pitch: pitch)
            }
        }
        .frame(width: hitWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointerY = location.y
            case .ended:
                pointerY = nil
            }
        }
        .onTapGesture { location in
            if let index = UserMessageNavigatorModel.index(atY: location.y, pitch: pitch, entryCount: entries.count) {
                onSelect(entries[index].id)
            }
        }
        .overlay(alignment: .topLeading) {
            if let hoveredIndex {
                NavigatorPreviewCard(
                    preview: entries[hoveredIndex].preview,
                    isActive: entries[hoveredIndex].id == activeID
                )
                .offset(x: hitWidth, y: CGFloat(hoveredIndex) * pitch + pitch / 2 - 18)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: pointerY)
        .animation(.easeInOut(duration: 0.15), value: hoveredIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your messages")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("transcript.userMessageNavigator")
        .accessibilityAdjustableAction { direction in
            let step: Int
            switch direction {
            case .increment: step = 1
            case .decrement: step = -1
            @unknown default: return
            }
            if let target = UserMessageNavigatorModel.adjacentEntryID(from: activeID, step: step, in: entries) {
                onSelect(target)
            }
        }
    }

    private var accessibilityValue: String {
        guard let index = entries.firstIndex(where: { $0.id == activeID }) else {
            return "\(entries.count) messages"
        }
        return "\(index + 1) of \(entries.count): \(entries[index].preview)"
    }

    private func tick(for entry: UserMessageNavigatorModel.Entry, index: Int, pitch: CGFloat) -> some View {
        let centerY = CGFloat(index) * pitch + pitch / 2
        let proximity = UserMessageNavigatorModel.proximity(distance: pointerY.map { abs($0 - centerY) })
        let isActive = entry.id == activeID
        let isHovered = index == hoveredIndex
        let width = (isActive ? activeTickWidth : restingTickWidth) + proximityGrowth * proximity
        let color: Color = isActive || isHovered
            ? Color.primary.opacity(0.85)
            : Color.secondary.opacity(0.35 + 0.4 * proximity)

        return Capsule()
            .fill(color)
            .frame(width: width, height: 2)
            .frame(height: pitch)
    }
}

private struct NavigatorPreviewCard: View {
    let preview: String
    let isActive: Bool

    var body: some View {
        Text(preview)
            .font(AppTypography.interfaceCaption)
            .foregroundStyle(isActive ? Color.primary : AppColors.textSecondary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(width: 260, alignment: .leading)
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.bubble, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.bubble, style: .continuous)
                    .stroke(AppColors.borderMuted, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
    }
}
