import XCTest
@testable import SSHKeeperCore

@MainActor
final class PanelWorkspaceTests: XCTestCase {

    // MARK: - open

    func testOpenAddsAndActivates() throws {
        let ws = PanelWorkspace()
        let a = UUID()
        try ws.open(panelID: a)
        XCTAssertEqual(ws.panelIDs, [a])
        XCTAssertEqual(ws.activePanelID, a)
    }

    func testOpenSameIDTwiceJustActivates() throws {
        let ws = PanelWorkspace()
        let a = UUID()
        let b = UUID()
        try ws.open(panelID: a)
        try ws.open(panelID: b)
        // 重新打开 a → 不再追加，只激活
        try ws.open(panelID: a)
        XCTAssertEqual(ws.panelIDs, [a, b])
        XCTAssertEqual(ws.activePanelID, a)
    }

    func testOpenThrowsAtTabLimit() throws {
        let ws = PanelWorkspace()
        let ids = (0..<PanelWorkspace.maxTabs).map { _ in UUID() }
        for id in ids { try ws.open(panelID: id) }
        XCTAssertEqual(ws.panelIDs.count, PanelWorkspace.maxTabs)
        XCTAssertThrowsError(try ws.open(panelID: UUID())) { error in
            guard case PanelWorkspaceError.tooManyTabs(let limit) = error else {
                XCTFail("expected tooManyTabs, got \(error)")
                return
            }
            XCTAssertEqual(limit, PanelWorkspace.maxTabs)
        }
    }

    func testOpenAtLimitDoesNotThrowIfAlreadyOpen() throws {
        // 已在 tab 列表里 → contains 短路，不进 maxTabs 检查，不应该报错
        let ws = PanelWorkspace()
        let ids = (0..<PanelWorkspace.maxTabs).map { _ in UUID() }
        for id in ids { try ws.open(panelID: id) }
        XCTAssertNoThrow(try ws.open(panelID: ids.first!))
    }

    // MARK: - close

    func testCloseMiddleMovesActiveToSameIndex() throws {
        let ws = PanelWorkspace()
        let (a, b, c) = (UUID(), UUID(), UUID())
        try ws.open(panelID: a)
        try ws.open(panelID: b)
        try ws.open(panelID: c)
        ws.setActive(b)
        ws.close(panelID: b)
        XCTAssertEqual(ws.panelIDs, [a, c])
        // b 原本在 idx 1，移除后 idx 1 是 c → 激活 c
        XCTAssertEqual(ws.activePanelID, c)
    }

    func testCloseLastMovesActiveToPrevious() throws {
        let ws = PanelWorkspace()
        let (a, b) = (UUID(), UUID())
        try ws.open(panelID: a)
        try ws.open(panelID: b)
        // b 是最后一个
        ws.close(panelID: b)
        XCTAssertEqual(ws.panelIDs, [a])
        XCTAssertEqual(ws.activePanelID, a)
    }

    func testCloseOnlyTabSetsActiveNil() throws {
        let ws = PanelWorkspace()
        let a = UUID()
        try ws.open(panelID: a)
        ws.close(panelID: a)
        XCTAssertTrue(ws.panelIDs.isEmpty)
        XCTAssertNil(ws.activePanelID)
    }

    func testCloseNonExistentIsNoOp() throws {
        let ws = PanelWorkspace()
        let a = UUID()
        try ws.open(panelID: a)
        ws.close(panelID: UUID())  // 不存在
        XCTAssertEqual(ws.panelIDs, [a])
        XCTAssertEqual(ws.activePanelID, a)
    }

    func testCloseInactiveTabKeepsActive() throws {
        let ws = PanelWorkspace()
        let (a, b) = (UUID(), UUID())
        try ws.open(panelID: a)
        try ws.open(panelID: b)
        ws.setActive(a)
        ws.close(panelID: b)
        XCTAssertEqual(ws.panelIDs, [a])
        XCTAssertEqual(ws.activePanelID, a)
    }

    // MARK: - setActive

    func testSetActiveExistingChanges() throws {
        let ws = PanelWorkspace()
        let (a, b) = (UUID(), UUID())
        try ws.open(panelID: a)
        try ws.open(panelID: b)
        ws.setActive(a)
        XCTAssertEqual(ws.activePanelID, a)
    }

    func testSetActiveNonExistentIsNoOp() throws {
        let ws = PanelWorkspace()
        let a = UUID()
        try ws.open(panelID: a)
        ws.setActive(UUID())  // 不存在 → 不改
        XCTAssertEqual(ws.activePanelID, a)
    }

    // MARK: - closeAll

    func testCloseAllEmptiesEverything() throws {
        let ws = PanelWorkspace()
        try ws.open(panelID: UUID())
        try ws.open(panelID: UUID())
        ws.closeAll()
        XCTAssertTrue(ws.panelIDs.isEmpty)
        XCTAssertNil(ws.activePanelID)
    }
}
