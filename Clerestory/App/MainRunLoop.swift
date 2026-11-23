import CoreFoundation

/// Runs work on the main thread through the main run loop instead of the main dispatch queue.
///
/// AppKit can wait for a reply, such as `reply(toApplicationShouldTerminate:)`, in a nested
/// run loop that starts inside a block already running on the main dispatch queue, for example
/// when Sparkle asks the app to quit. Main-queue blocks and main-actor tasks can't run until
/// that block returns, so a reply sent through them never arrives (#123). The run loop still
/// performs blocks scheduled for its common modes, which include the mode AppKit waits in.
enum MainRunLoop {
    nonisolated static func perform(_ body: @escaping @MainActor @Sendable () -> Void) {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated(body)
        }
        CFRunLoopWakeUp(loop)
    }
}
