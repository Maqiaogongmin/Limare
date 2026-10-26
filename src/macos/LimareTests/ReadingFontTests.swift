import XCTest
import AppKit
import CoreText
@testable import Limare

@MainActor
final class ReadingFontTests: XCTestCase {
    private func weight(of font: NSFont) -> Double? {
        let variation = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        return variation?[NSNumber(value: 0x7767_6874)]?.doubleValue
    }

    func testBundledSerifRegistersWithItsWeights() {
        let regular = ReadingFont.regular(size: 14)
        XCTAssertEqual(regular.familyName, "Noto Serif SC")
        XCTAssertEqual(regular.pointSize, 14)
        XCTAssertEqual(weight(of: regular), 400)
        let url = CTFontCopyAttribute(regular, kCTFontURLAttribute) as? URL
        XCTAssertEqual(url?.lastPathComponent, "NotoSerifSC-VF.ttf", "The font is the one bundled with the app")

        let semibold = ReadingFont.semibold(size: 14)
        XCTAssertEqual(semibold.familyName, "Noto Serif SC")
        XCTAssertEqual(weight(of: semibold), 600)
    }

    func testFontsAreMadeOncePerSizeAndWeight() {
        XCTAssertTrue(ReadingFont.regular(size: 15) === ReadingFont.regular(size: 15))
        XCTAssertTrue(ReadingFont.semibold(size: 15) === ReadingFont.semibold(size: 15))
        XCTAssertFalse(ReadingFont.regular(size: 15) === ReadingFont.semibold(size: 15))
    }

    func testBundledFontCoversCJK() {
        let font = ReadingFont.regular(size: 14)
        let text = "思源宋体" as NSString
        var characters = [UniChar](repeating: 0, count: text.length)
        text.getCharacters(&characters, range: NSRange(location: 0, length: text.length))
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
    }
}
