import AppKit
import ApplicationServices
import BouncerCore
import XCTest
@testable import TypoBouncer

private actor DelayedProofreader: ProofreadingService {
    private(set) var calls = 0
    func prewarm() { }
    func correct(_ text: String, limit: Int, command: Command) async throws -> ValidatedCorrection {
        calls += 1
        // Deliberately completes after cancellation to test stale-result suppression.
        try? await Task.sleep(for: .milliseconds(150))
        return try OutputValidator.validate(original: text, corrected: text.replacingOccurrences(of: "teh", with: "the"))
    }
}

private actor TestSelection: SelectionCapturing {
    let text: String
    init(_ text: String = "teh cat") { self.text = text }
    func capture(pid: pid_t) -> CapturedSelection {
        CapturedSelection(element: AXUIElementCreateApplication(pid), canReplace: true, pid: pid,
            text: text, range: CFRange(location: 0, length: text.utf16.count), fullValue: text, digest: Data())
    }
    func verify(_ target: CapturedSelection) { }
    func confirms(_ target: CapturedSelection, replacement: String) -> Bool { true }
}

@MainActor final class ProofreadingTests: XCTestCase {
    func testSingleFlightAndCancelledResultDoesNotReappear() async throws {
        let service = DelayedProofreader()
        let coordinator = ProofreadingCoordinator(service: service, capture: TestSelection())
        coordinator.proofreadSelection(pid: 123, limit: 1500)
        coordinator.proofreadSelection(pid: 123, limit: 1500)
        try await Task.sleep(for: .milliseconds(30))
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        coordinator.cancel()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(coordinator.working)
        XCTAssertNil(coordinator.result)
    }
    func testTimeoutDiscardsLateCompletion() async throws {
        var pastes = 0
        let coordinator = ProofreadingCoordinator(service: DelayedProofreader(), timeout: 0.05,
            capture: TestSelection(), insert: { _, _ in pastes += 1 })
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .full)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(coordinator.working)
        XCTAssertNil(coordinator.result)
        XCTAssertEqual(coordinator.message, AppFailure.timedOut.message)
        XCTAssertEqual(pastes, 0)
    }
    func testUnchangedSelectionCannotApply() async throws {
        var pastes = 0
        let coordinator = ProofreadingCoordinator(service: DelayedProofreader(),
            capture: TestSelection("the cat"), insert: { _, _ in pastes += 1 })
        coordinator.proofreadSelection(pid: 123, limit: 1500)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(coordinator.result?.isUnchanged == true)
        XCTAssertFalse(coordinator.canApply)
        coordinator.apply()
        XCTAssertEqual(pastes, 0)
    }
}

@MainActor final class ClipboardGuardTests: XCTestCase {
    func testMultipleItemsAndCustomDataRoundTrip() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("test.synthetic.bytes")
        let first = NSPasteboardItem(); first.setString("synthetic clipboard", forType: .string)
        first.setData(Data([0, 1, 255, 0]), forType: custom)
        let second = NSPasteboardItem(); second.setData(Data([9, 8, 7]), forType: .png)
        XCTAssertTrue(board.writeObjects([first, second]))
        let guarder = ClipboardGuard(pasteboard: board)
        let saved = try guarder.snapshot()
        let owned = try guarder.writeTemporary("synthetic correction", after: saved)
        XCTAssertTrue(guarder.owns(owned))
        guarder.restore(saved, ifOwned: owned)
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(board.pasteboardItems?.first?.data(forType: custom), Data([0, 1, 255, 0]))
        XCTAssertEqual(board.pasteboardItems?.last?.data(forType: .png), Data([9, 8, 7]))
    }
    func testNewClipboardOwnerIsNeverOverwritten() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let guarder = ClipboardGuard(pasteboard: board)
        let snapshot = try guarder.snapshot()
        let ownership = try guarder.writeTemporary("temporary", after: snapshot)
        board.clearContents(); board.setString("new copy", forType: .string)
        guarder.restore(snapshot, ifOwned: ownership)
        XCTAssertEqual(board.string(forType: .string), "new copy")
        XCTAssertThrowsError(try guarder.writeTemporary("stale", after: snapshot))
        XCTAssertEqual(board.string(forType: .string), "new copy")
    }
    func testOversizedSnapshotRefusesWithoutWriting() {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("long synthetic text", forType: .string)
        let count = board.changeCount
        XCTAssertThrowsError(try ClipboardGuard(pasteboard: board, maximumBytes: 2).snapshot())
        XCTAssertEqual(board.changeCount, count)
    }
}

private actor FakeSelectionVerifier: SelectionVerifying {
    let shouldFail: Bool
    init(shouldFail: Bool) { self.shouldFail = shouldFail }
    func verify(_ target: CapturedSelection) throws { if shouldFail { throw AppFailure.focusChanged } }
    func confirms(_ target: CapturedSelection, replacement: String) -> Bool { true }
}

@MainActor final class TextInserterTests: XCTestCase {
    private func target() -> CapturedSelection {
        CapturedSelection(element: AXUIElementCreateApplication(123), canReplace: true, pid: 123,
                          text: "teh", range: CFRange(location: 0, length: 3), fullValue: "teh", digest: Data())
    }
    func testSelectionMismatchNeverWritesOrPastes() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("saved clipboard", forType: .string); let count = board.changeCount
        var pasted = false
        let inserter = TextInserter(capture: FakeSelectionVerifier(shouldFail: true), clipboard: ClipboardGuard(pasteboard: board),
                                    frontmost: { 123 }, paste: { pasted = true }, settleTime: .zero)
        do { try await inserter.apply("the", to: target()); XCTFail("Mismatch accepted") }
        catch { XCTAssertEqual(error as? AppFailure, .focusChanged) }
        XCTAssertFalse(pasted); XCTAssertEqual(board.changeCount, count)
    }
    func testFrontmostMismatchNeverWritesOrPastes() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("saved clipboard", forType: .string); let count = board.changeCount
        var pasted = false
        let inserter = TextInserter(capture: FakeSelectionVerifier(shouldFail: false), clipboard: ClipboardGuard(pasteboard: board),
                                    frontmost: { 999 }, paste: { pasted = true }, settleTime: .zero)
        do { try await inserter.apply("the", to: target()); XCTFail("Focus mismatch accepted") } catch { }
        XCTAssertFalse(pasted); XCTAssertEqual(board.changeCount, count)
    }
    func testVerifiedPasteRestoresClipboardEvenIfPasteThrows() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("saved clipboard", forType: .string)
        var pasted = false
        let inserter = TextInserter(capture: FakeSelectionVerifier(shouldFail: false), clipboard: ClipboardGuard(pasteboard: board),
                                    frontmost: { 123 }, paste: { pasted = true; throw AppFailure.pasteFailed }, settleTime: .zero)
        do { try await inserter.apply("the", to: target()); XCTFail("Paste should fail") } catch { }
        XCTAssertTrue(pasted); XCTAssertEqual(board.string(forType: .string), "saved clipboard")
    }
}
