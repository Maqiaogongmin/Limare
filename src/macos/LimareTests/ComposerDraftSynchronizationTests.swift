import AppKit
import SwiftUI
import XCTest
@testable import Limare

@MainActor
final class ComposerDraftSynchronizationTests: XCTestCase {
    private final class Draft { var text = "" }

    private func makeEditor(_ draft: Draft) -> (NativeDraftTextViewRepresentable.Coordinator, NativeAppKitDraftTextView) {
        let editor = NativeDraftTextViewRepresentable(
            text: Binding(get: { draft.text }, set: { draft.text = $0 }),
            placeholder: "", font: .systemFont(ofSize: 14), onFilesDropped: nil,
            onSend: {}, onFocusChange: { _ in }, onContentHeightChange: nil,
            onMenuKey: nil, focusToken: 0
        )
        let coordinator = editor.makeCoordinator()
        let view = NativeAppKitDraftTextView(usingTextLayoutManager: true)
        coordinator.textView = view
        view.delegate = coordinator
        view.onMarkedTextChange = { [weak coordinator] in coordinator?.markedTextDidChange() }
        return (coordinator, view)
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testReplacementIsDeferredAndUsesLatestDraft() async {
        let draft = Draft()
        let (coordinator, view) = makeEditor(draft)
        view.string = "previous conversation"
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        draft.text = "first selection"
        coordinator.scheduleTextSynchronization()
        XCTAssertEqual(view.string, "previous conversation")
        draft.text = "latest selection"
        coordinator.scheduleTextSynchronization()
        await nextMainTurn()
        XCTAssertEqual(view.string, "latest selection")
        XCTAssertEqual(view.selectedRange().location, draft.text.utf16.count)
    }

    func testMarkedTextIsNotReplacedAndCommittedTextIsRetained() async {
        let draft = Draft()
        let (coordinator, view) = makeEditor(draft)
        view.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        draft.text = "other draft"
        coordinator.scheduleTextSynchronization()
        await nextMainTurn()
        XCTAssertEqual(view.string, "输入")
        view.unmarkText()
        await nextMainTurn()
        XCTAssertEqual(view.string, "输入")
        XCTAssertEqual(draft.text, "输入")
    }

    func testSwitchCapturesAndEndsMarkedComposition() {
        let draft = Draft()
        let (_, view) = makeEditor(draft)
        view.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.endCompositionForConversationSwitch(), "输入")
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertNil(view.endCompositionForConversationSwitch())
    }

    func testTypingBeforeQueuedUpdateIsNotOverwritten() async {
        let draft = Draft()
        let (coordinator, view) = makeEditor(draft)
        coordinator.scheduleTextSynchronization()
        view.insertText("新文字", replacementRange: NSRange(location: 0, length: 0))
        await nextMainTurn()
        XCTAssertEqual(draft.text, "新文字")
        XCTAssertEqual(view.string, "新文字")
    }
}
