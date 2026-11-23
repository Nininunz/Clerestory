import XCTest
@testable import Clerestory

@MainActor
final class IslandNotchIndicatorResolverTests: XCTestCase {
    private let low = IslandStatus(key: "low", title: "Battery low", detail: "15%",
                                   systemImage: "battery.25percent", tone: .critical, announcesWhenRaised: false)
    private let playing = IslandStatus(key: "playing", title: "Song", detail: "Artist",
                                       systemImage: "waveform", announcesWhenRaised: false)
    private let transfer = IslandStatus(key: "transfer", title: "Transferring content…",
                                        systemImage: "arrow.up.arrow.down", tone: .progress)

    private func makeCenter(started modules: [IslandModuleID]) -> IslandMessageCenter {
        let center = IslandMessageCenter.forTesting()
        for module in modules { center.moduleDidStart(module) }
        return center
    }

    private func resolve(_ display: IslandModuleID?, _ center: IslandMessageCenter,
                         dragging: Bool = false) -> IslandNotchIndicator? {
        IslandNotchIndicatorResolver.resolve(display: display, center: center, isDragInProgress: dragging)
    }

    /// What the presenter does once the pill is on screen.
    private func showCurrentNotice(_ center: IslandMessageCenter) {
        center.setVisibleNotice(center.currentNotice?.id)
    }

    private let power = IslandNotice(key: "power", title: "Power connected · 15%",
                                     detail: "Power connected, 15%", systemImage: "bolt.fill")

    func testNothingToShowUsesTheDefaultIcon() {
        let center = makeCenter(started: [.battery])
        XCTAssertNil(resolve(.battery, center))
        XCTAssertNil(resolve(nil, center))
    }

    func testDisplayedModulesVisibleNoticeBeatsItsStatus() {
        let center = makeCenter(started: [.battery])
        center.messenger(for: .battery).setStatus(low)
        XCTAssertEqual(resolve(.battery, center),
                       IslandNotchIndicator(systemImage: "battery.25percent", tint: .critical, accessibilityText: "Battery low"))

        center.messenger(for: .battery).post(power)
        showCurrentNotice(center)
        XCTAssertEqual(resolve(.battery, center),
                       IslandNotchIndicator(systemImage: "bolt.fill", tint: .neutral,
                                            accessibilityText: "Battery low", "Power connected, 15%"))

        center.messenger(for: .battery).withdrawNotice("power")
        XCTAssertEqual(resolve(.battery, center)?.tint, .critical)
    }

    func testAnotherModulesNoticeDoesNotChangeTheDisplay() {
        let center = makeCenter(started: [.media])
        center.messenger(for: .media).setStatus(playing)
        center.messenger(for: .shelf).post(.alreadyOnShelf)
        showCurrentNotice(center)
        XCTAssertEqual(resolve(.media, center)?.systemImage, "waveform")
    }

    func testNoticeToneSetsTheTint() {
        let center = makeCenter(started: [])
        let cases: [(IslandNotice.Tone, IslandStatus.Tone)] = [
            (.info, .neutral), (.success, .neutral), (.warning, .warning), (.error, .critical),
        ]
        for (tone, tint) in cases {
            center.messenger(for: .timer).post(IslandNotice(key: "n", title: "Notice", tone: tone))
            showCurrentNotice(center)
            XCTAssertEqual(resolve(.timer, center)?.tint, tint, "\(tone)")
        }
    }

    func testShelfShowsTheDragArrowDuringADrag() {
        let center = makeCenter(started: [.shelf])
        XCTAssertNil(resolve(.shelf, center))
        XCTAssertEqual(resolve(.shelf, center, dragging: true),
                       IslandNotchIndicator(systemImage: IslandNotchIndicatorResolver.dragSystemImage,
                                            tint: .progress, accessibilityText: "Drop into Clerestory"))
        XCTAssertNil(resolve(.timer, center, dragging: true), "Only the Shelf display shows the drag")
    }

    /// A waiting notice's clock is stopped, so it must not hold the icon while it waits, for
    /// example behind an unpinned Panel on another display.
    func testANoticeThatWaitsDoesNotReplaceTheStatus() {
        let center = makeCenter(started: [.battery])
        center.messenger(for: .battery).setStatus(low)
        center.messenger(for: .battery).post(power)
        XCTAssertNotNil(center.currentNotice)
        XCTAssertEqual(resolve(.battery, center)?.tint, .critical, "Not on screen yet")

        showCurrentNotice(center)
        XCTAssertEqual(resolve(.battery, center)?.systemImage, "bolt.fill")

        center.setVisibleNotice(nil)
        XCTAssertEqual(resolve(.battery, center)?.systemImage, "battery.25percent", "Waiting again, for example during a drag")
    }

    /// The presenter hides the pill during a drag, so a current Shelf notice does not cover the
    /// drag arrow.
    func testAShelfNoticeHiddenByADragKeepsTheDragArrow() {
        let center = makeCenter(started: [.shelf])
        center.messenger(for: .shelf).post(.removed)
        showCurrentNotice(center)
        XCTAssertEqual(resolve(.shelf, center)?.systemImage, ShelfNotice.removed.notice.symbol)

        center.setVisibleNotice(nil)
        XCTAssertEqual(resolve(.shelf, center, dragging: true),
                       IslandNotchIndicator(systemImage: IslandNotchIndicatorResolver.dragSystemImage,
                                            tint: .progress, accessibilityText: "Drop into Clerestory"))
    }

    func testAnotherModulesCriticalStatusReplacesANeutralDisplay() {
        let center = makeCenter(started: [.media, .battery, .system])
        center.messenger(for: .media).setStatus(playing)
        XCTAssertEqual(resolve(.media, center)?.systemImage, "waveform")

        center.messenger(for: .battery).setStatus(low)
        XCTAssertEqual(resolve(.media, center),
                       IslandNotchIndicator(systemImage: "battery.25percent", tint: .critical, accessibilityText: "Battery low"))
        XCTAssertEqual(resolve(nil, center)?.tint, .critical, "The fallback display borrows it too")

        center.messenger(for: .battery).clearStatus("low")
        center.messenger(for: .system).setStatus(.init(key: "disk", title: "Disk space is low",
                                                       systemImage: "externaldrive", tone: .warning))
        XCTAssertEqual(resolve(.media, center)?.systemImage, "waveform", "Only critical statuses are borrowed")
    }

    func testOwnWarningBeatsAnotherModulesCriticalStatus() {
        let center = makeCenter(started: [.timer, .battery])
        center.messenger(for: .battery).setStatus(low)
        center.messenger(for: .timer).setStatus(.init(key: "finished", title: "Timer finished",
                                                      systemImage: "timer", tone: .warning))
        XCTAssertEqual(resolve(.timer, center)?.tint, .warning)
    }

    func testLatestCriticalStatusIsBorrowed() {
        let center = makeCenter(started: [.battery, .system])
        center.messenger(for: .battery).setStatus(low)
        center.messenger(for: .system).setStatus(.init(key: "thermal", title: "Mac thermal state is critical",
                                                       systemImage: "thermometer.high", tone: .critical))
        XCTAssertEqual(resolve(.media, center)?.accessibilityText, "Mac thermal state is critical")
    }

    /// The hazard this replaces: a transfer or a drag outranked Battery's activity, so the
    /// Battery display lost its red tint.
    func testATransferOrADragNeverRemovesBatterysRedTint() {
        let center = makeCenter(started: [.battery, .transfers])
        center.messenger(for: .battery).setStatus(low)
        center.messenger(for: .transfers).setStatus(transfer)
        XCTAssertEqual(resolve(.battery, center, dragging: true)?.tint, .critical)
        XCTAssertEqual(resolve(.transfers, center)?.tint, .critical, "A critical status outranks a transfer in progress")
        XCTAssertEqual(resolve(.shelf, center, dragging: true)?.systemImage,
                       IslandNotchIndicatorResolver.dragSystemImage)
    }

    func testDisplayedModulesOwnStatusShowsWithoutOtherModules() {
        let center = makeCenter(started: [.transfers])
        center.messenger(for: .transfers).setStatus(transfer)
        XCTAssertEqual(resolve(.transfers, center),
                       IslandNotchIndicator(systemImage: "arrow.up.arrow.down", tint: .progress,
                                            accessibilityText: "Transferring content…"))
    }

    func testLabelGetsTheStatusSuffix() {
        let center = makeCenter(started: [.battery, .media])
        center.messenger(for: .battery).setStatus(low)
        let battery = resolve(.battery, center)
        XCTAssertEqual(IslandNotchIndicatorResolver.accessibilityLabel("Battery, 15 percent", indicator: battery),
                       "Battery, 15 percent, Battery low")
        XCTAssertEqual(IslandNotchIndicatorResolver.accessibilityLabel("Battery, 15 percent", indicator: nil),
                       "Battery, 15 percent")
        center.messenger(for: .battery).clearStatus("low")
        center.messenger(for: .media).setStatus(playing)
        XCTAssertEqual(IslandNotchIndicatorResolver.accessibilityLabel("Song", indicator: resolve(.media, center)),
                       "Song", "The label does not repeat what it already says")
    }

    /// A notice never hides a status, for VoiceOver either.
    func testLabelKeepsTheStatusWhileANoticeShows() {
        let center = makeCenter(started: [.battery, .media])
        center.messenger(for: .battery).setStatus(low)
        center.messenger(for: .battery).post(power)
        showCurrentNotice(center)
        XCTAssertEqual(IslandNotchIndicatorResolver.accessibilityLabel("Battery, 15 percent",
                                                                       indicator: resolve(.battery, center)),
                       "Battery, 15 percent, Battery low, Power connected, 15%")

        center.messenger(for: .battery).withdrawNotice("power")
        center.messenger(for: .media).setStatus(playing)
        center.messenger(for: .media).post(IslandNotice(key: "n", title: "Paused"))
        showCurrentNotice(center)
        XCTAssertEqual(IslandNotchIndicatorResolver.accessibilityLabel("Song", indicator: resolve(.media, center)),
                       "Song, Battery low, Paused", "The borrowed critical status stays in the label")
    }

    private func borrowed(_ display: IslandModuleID?, _ center: IslandMessageCenter,
                          dragging: Bool = false) -> IslandModuleID? {
        IslandNotchIndicatorResolver.borrowedModule(display: display, center: center, isDragInProgress: dragging)
    }

    func testBorrowedModuleIsTheModuleWhoseCriticalStatusTheIconShows() {
        let center = makeCenter(started: [.shelf, .media, .battery])
        XCTAssertNil(borrowed(.shelf, center))

        center.messenger(for: .battery).setStatus(low)
        XCTAssertEqual(borrowed(.shelf, center), .battery)
        XCTAssertEqual(borrowed(nil, center), .battery, "The fallback display borrows it too")
        XCTAssertNil(borrowed(.battery, center), "Battery shows its own status")

        center.messenger(for: .battery).clearStatus("low")
        XCTAssertNil(borrowed(.shelf, center))
    }

    func testNothingIsBorrowedWhileTheDisplaysOwnNoticeDragOrWarningShows() {
        let center = makeCenter(started: [.shelf, .media, .battery])
        center.messenger(for: .battery).setStatus(low)

        XCTAssertNil(borrowed(.shelf, center, dragging: true))

        center.messenger(for: .shelf).post(.removed)
        showCurrentNotice(center)
        XCTAssertNil(borrowed(.shelf, center))
        center.setVisibleNotice(nil)
        XCTAssertEqual(borrowed(.shelf, center), .battery)

        center.messenger(for: .media).setStatus(.init(key: "warn", title: "Warning",
                                                      systemImage: "exclamationmark.triangle", tone: .warning))
        XCTAssertNil(borrowed(.media, center), "The display's own warning wins")
    }
}
