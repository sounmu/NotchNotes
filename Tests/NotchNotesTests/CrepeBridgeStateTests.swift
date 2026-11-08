import XCTest
@testable import NotchNotes

final class CrepeBridgeStateTests: XCTestCase {
    func testLateMessagesAreScopedToNoteGenerationAndRevision() {
        let first = UUID(), second = UUID(), old = UUID(), current = UUID()
        var state = CrepeBridgeState()
        state.begin(first, generation: old)
        state.begin(second, generation: current)
        func snapshot(_ id: UUID, _ generation: UUID, _ revision: Int) -> CrepeSnapshot {
            .init(id: id, generation: generation, revision: revision, markdown: "value",
                  selection: .init(anchor: 1, head: 1), active: [], mixed: [])
        }
        XCTAssertTrue(state.accept(snapshot(first, old, 2), existingIDs: [first, second]))
        XCTAssertFalse(state.accept(snapshot(first, old, 2), existingIDs: [first, second]))
        XCTAssertFalse(state.accept(snapshot(first, old, 1), existingIDs: [first, second]))
        state.begin(first, generation: current)
        XCTAssertFalse(state.accept(snapshot(first, old, 3), existingIDs: [first, second]))
        XCTAssertTrue(state.accept(snapshot(first, current, 0), existingIDs: [first, second]))
        XCTAssertFalse(state.accept(snapshot(second, current, 1), existingIDs: [first]))
    }
}
