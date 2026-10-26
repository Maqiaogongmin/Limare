import AppKit
import CoreText
import os

/// The font replies and document previews are read in: Noto Serif SC, a variable font bundled
/// with the app (OFL-1.1, see THIRD_PARTY_LICENSES.md). The chrome, user bubbles, the composer
/// and code stay on the system fonts.
///
/// Weights come from the font's `wght` axis, never from a bold trait: 400 for the text, 600
/// for bold and headings (700 reads too heavy in CJK). Chinese has no italic, and a slanted
/// serif reads badly, so italic text is set upright; emphasis keeps its underline.
@MainActor
enum ReadingFont {
    static let familyName = "Noto Serif SC"
    private static let fileName = "NotoSerifSC-VF"
    /// `wght`, the variation axis tag.
    private static let weightAxis = 0x7767_6874

    static func regular(size: CGFloat) -> NSFont {
        font(size: size, weight: 400)
    }

    static func semibold(size: CGFloat) -> NSFont {
        font(size: size, weight: 600)
    }

    /// Fonts already made, by size and weight. A theme is rebuilt on every SwiftUI update and
    /// compared with the last one; the same font object keeps the two equal.
    private static var cache: [CacheKey: NSFont] = [:]

    private struct CacheKey: Hashable {
        let size: CGFloat
        let weight: Int
    }

    private static func font(size: CGFloat, weight: Int) -> NSFont {
        let key = CacheKey(size: size, weight: weight)
        if let font = cache[key] {
            return font
        }
        let font = make(size: size, weight: weight)
        cache[key] = font
        return font
    }

    private static func make(size: CGFloat, weight: Int) -> NSFont {
        if isRegistered {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: familyName,
                .variation: [NSNumber(value: weightAxis): NSNumber(value: weight)],
            ])
            if let font = NSFont(descriptor: descriptor, size: size), font.familyName == familyName {
                return font
            }
        }
        return .systemFont(ofSize: size, weight: weight >= 600 ? .semibold : .regular)
    }

    /// Registers the bundled file for this process, once, the first time a font is asked for:
    /// it does not depend on the app's launch order, and works the same in a test host. A
    /// debug app build stops when the file is missing; anything else (a release build, the
    /// script suites compiled without the bundle) logs it and uses the system font.
    private static let isRegistered: Bool = {
        let logger = Logger(subsystem: LimareStorage.bundleIdentifier, category: "ReadingFont")
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "ttf") else {
            logger.error("\(fileName, privacy: .public).ttf is missing from the bundle")
            #if DEBUG
            assertionFailure("\(fileName).ttf is missing from the bundle")
            #endif
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            return true
        }
        let cfError = error?.takeRetainedValue()
        if let cfError, CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue {
            return true
        }
        logger.error("Registering \(fileName, privacy: .public).ttf failed: \(String(describing: cfError), privacy: .public)")
        #if DEBUG
        assertionFailure("Registering \(fileName).ttf failed: \(String(describing: cfError))")
        #endif
        return false
    }()
}
