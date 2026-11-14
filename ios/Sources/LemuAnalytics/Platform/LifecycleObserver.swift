#if canImport(UIKit) && (os(iOS) || os(tvOS))
import Foundation
import UIKit

/// Listens to UIApplication notifications for app_opened and
/// app_backgrounded, and flushes when the app goes to the background.
///
/// Uses notifications only (no `UIApplication.shared`), so the SDK also links
/// in app extensions.
final class LemuLifecycleObserver {
    private weak var client: LemuClient?
    private let trackLifecycle: Bool
    private var tokens: [NSObjectProtocol] = []
    private var coldOpenPending = true
    private let lock = NSLock()

    init(client: LemuClient, trackLifecycle: Bool) {
        self.client = client
        self.trackLifecycle = trackLifecycle
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.didBecomeActive()
        })
        tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.willEnterForeground()
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.didEnterBackground()
        })
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// The first activation after launch is the cold open. Later activations
    /// without a trip to the background (an alert, Control Center) are not opens.
    private func didBecomeActive() {
        lock.lock()
        let isColdOpen = coldOpenPending
        coldOpenPending = false
        lock.unlock()
        if isColdOpen, trackLifecycle {
            client?.trackApplicationOpened(fromBackground: false)
        }
    }

    private func willEnterForeground() {
        lock.lock()
        coldOpenPending = false
        lock.unlock()
        if trackLifecycle {
            client?.trackApplicationOpened(fromBackground: true)
        }
    }

    private func didEnterBackground() {
        guard let client = client else { return }
        if trackLifecycle {
            client.trackApplicationBackgrounded()
        }
        LemuLifecycleObserver.flushInBackground(client)
    }

    /// Asks the system for time to finish sending. `performExpiringActivity`
    /// works in apps and app extensions alike.
    static func flushInBackground(_ client: LemuClient) {
        let done = DispatchSemaphore(value: 0)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Lemu: send queued events") { expired in
            if expired {
                done.signal()
                return
            }
            client.flush { done.signal() }
            _ = done.wait(timeout: .now() + 25)
        }
    }
}
#endif
