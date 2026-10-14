import SwiftUI
import AppKit

struct AssistantAvatarView: View {
    let image: NSImage?
    var size: CGFloat = 24

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
        } else {
            // No custom avatar: the app icon's mark on the icon's own tile, light or dark with it.
            Image(Self.markCut(for: size))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .accessibilityHidden(true)
        }
    }

    /// The icon's strokes thin toward a hairline as it shrinks, so smaller avatars use a
    /// slightly heavier cut of the same artwork, the way a font has optical sizes.
    private static func markCut(for size: CGFloat) -> String {
        switch size {
        case 44...: "LimareAvatar"
        case 28...: "LimareAvatarMedium"
        default: "LimareAvatarSmall"
        }
    }
}

/// The Limare mark from the app icon, as a template image that takes the foreground style.
struct LimareGlyph: View {
    var size: CGFloat

    var body: some View {
        Image("LimareGlyph")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
