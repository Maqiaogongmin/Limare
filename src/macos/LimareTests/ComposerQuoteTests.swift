import XCTest
@testable import Limare

final class ComposerQuoteTests: XCTestCase {
    func testQuotePreservesDraftAndEverySelectedLine() {
        XCTAssertEqual(ComposerQuote.appending("第一行\n\n第二行", to: "现有草稿"),
                       "现有草稿\n\n> 第一行\n>\n> 第二行\n\n")
        XCTAssertEqual(ComposerQuote.appending("😀\r\n  code", to: ""), "> 😀\n>   code\n\n")
        XCTAssertEqual(ComposerQuote.appending("next", to: "> earlier\n\n"), "> earlier\n\n> next\n\n")
        XCTAssertEqual(ComposerQuote.appending(" \n", to: "草稿"), "草稿")
    }
}
