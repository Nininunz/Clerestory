import XCTest
@testable import Clerestory

@MainActor
final class IslandMessageCenterTests: XCTestCase {
    func testPostReplacesCurrentNoticeAndBumpsRevision() throws {
        let center = IslandMessageCenter()
        let shelf = center.messenger(for: .shelf)
        shelf.post(.alreadyOnShelf)
        let first = try XCTUnwrap(center.current)
        XCTAssertEqual(first.moduleID, .shelf)
        XCTAssertEqual(first.notice, ShelfNotice.alreadyOnShelf.notice)
        XCTAssertEqual(first.revision, center.revision)

        center.messenger(for: .battery).post(IslandNotice(key: "power", title: "Power connected"))
        XCTAssertEqual(center.current?.moduleID, .battery)
        XCTAssertEqual(center.current?.notice.key, "power")
        XCTAssertGreaterThan(center.revision, first.revision)
    }

    func testWithdrawNoticeClearsOnlyItsOwnModuleAndKey() {
        let center = IslandMessageCenter()
        let shelf = center.messenger(for: .shelf)
        let battery = center.messenger(for: .battery)
        shelf.post(.removed)

        battery.withdrawNotice(ShelfNotice.removed.rawValue)
        XCTAssertEqual(center.current?.notice.key, ShelfNotice.removed.rawValue,
                       "Another module cannot withdraw a Shelf notice")
        shelf.withdrawNotice(ShelfNotice.reconnected.rawValue)
        XCTAssertNotNil(center.current, "A different key leaves the notice in place")
        shelf.withdrawNotice(ShelfNotice.removed.rawValue)
        XCTAssertNil(center.current)
    }

    func testInertMessengerHasNoCenter() {
        XCTAssertFalse(ModuleMessenger.inert.isConnected, "inert must not reach any message center")
        let center = IslandMessageCenter()
        XCTAssertTrue(center.messenger(for: .shelf).isConnected)
        // Posting and withdrawing through an inert messenger is a safe no-op.
        ModuleMessenger.inert.post(.alreadyOnShelf)
        ModuleMessenger.inert.withdrawNotice(ShelfNotice.alreadyOnShelf.rawValue)
    }

    func testPerformRoutesActionAndDismissesNotice() {
        let center = IslandMessageCenter()
        var routed: [IslandNoticeAction] = []
        center.routeAction = { routed.append($0) }
        center.messenger(for: .shelf).post(.receivedAwaitingRecovery)

        center.perform(.openStorageRecovery)
        XCTAssertEqual(routed, [.openStorageRecovery])
        XCTAssertNil(center.current)

        center.perform(.openModule(.timer))
        XCTAssertEqual(routed, [.openStorageRecovery, .openModule(.timer)])
    }

    func testNoticeDurationOverridesDefault() async throws {
        let center = IslandMessageCenter()
        center.messenger(for: .shelf).post(IslandNotice(key: "short", title: "Short", duration: 0.1))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(center.current)
    }

    func testActionTitles() {
        XCTAssertEqual(IslandNoticeAction.openStorageRecovery.title, "Open Recovery")
        XCTAssertEqual(IslandNoticeAction.openModule(.timer).title, "Show")
    }
}
