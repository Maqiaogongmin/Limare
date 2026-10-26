import XCTest
@testable import Limare

final class SettingsScrollEdgeFadeTests: XCTestCase {
    func testFadeShowsOnlyOnceContentHasScrolledPastTheTopEdge() {
        XCTAssertFalse(SettingsScrollEdgeFade.isScrolled(contentOffsetY: 0, contentInsetTop: 0))
        XCTAssertTrue(SettingsScrollEdgeFade.isScrolled(contentOffsetY: 1, contentInsetTop: 0))
        // At rest under a negative inset, the offset equals the inset's magnitude: not scrolled.
        XCTAssertFalse(SettingsScrollEdgeFade.isScrolled(contentOffsetY: 4, contentInsetTop: -4))
    }
}
