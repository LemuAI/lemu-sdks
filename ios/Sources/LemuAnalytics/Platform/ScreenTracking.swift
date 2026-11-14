import Foundation

#if canImport(SwiftUI)
import SwiftUI

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
struct LemuScreenModifier: ViewModifier {
    let name: String
    let properties: [String: Any]?

    func body(content: Content) -> some View {
        content.onAppear {
            Lemu.screen(name, properties: properties)
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension View {
    /// Records a screen view each time this view appears.
    ///
    /// ```swift
    /// CheckoutView().lemuScreen("Checkout")
    /// ```
    func lemuScreen(_ name: String, properties: [String: Any]? = nil) -> some View {
        modifier(LemuScreenModifier(name: name, properties: properties))
    }
}
#endif

#if canImport(UIKit) && (os(iOS) || os(tvOS))
import UIKit

/// Adopt to name a view controller's screen, or return nil to skip it, when
/// automatic screen tracking is on.
@objc(LemuScreenNameProviding)
public protocol LemuScreenNameProviding: AnyObject {
    /// The screen name to send, or nil to send nothing for this controller.
    var lemuScreenName: String? { get }
}

extension Lemu {
    /// Opt-in: records a screen view whenever one of your view controllers
    /// appears. The name is the class name without a `ViewController` suffix
    /// (`CheckoutViewController` becomes `Checkout`), or `lemuScreenName` when
    /// the controller adopts `LemuScreenNameProviding`.
    ///
    /// Container controllers (navigation, tab bar, split, page), UIKit's own
    /// controllers, SwiftUI hosting controllers and child controllers embedded
    /// in your own controllers are skipped. For SwiftUI screens use `.lemuScreen("Name")`.
    @objc public static func enableAutomaticScreenTracking() {
        LemuViewControllerTracker.install()
    }
}

enum LemuViewControllerTracker {
    private static let lock = NSLock()
    private static var installed = false

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        let cls: AnyClass = UIViewController.self
        guard
            let original = class_getInstanceMethod(cls, #selector(UIViewController.viewDidAppear(_:))),
            let replacement = class_getInstanceMethod(cls, #selector(UIViewController.lemu_viewDidAppear(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
        installed = true
    }

    static func viewDidAppear(_ controller: UIViewController) {
        guard let name = screenName(for: controller) else { return }
        Lemu.screen(name)
    }

    static func screenName(for controller: UIViewController) -> String? {
        if let provider = controller as? LemuScreenNameProviding {
            return provider.lemuScreenName
        }
        if controller is UINavigationController || controller is UITabBarController
            || controller is UISplitViewController || controller is UIPageViewController {
            return nil
        }
        #if os(iOS)
        if controller is UIAlertController { return nil }
        #endif
        // Only the app's own controllers: UIKit's, SwiftUI's hosting
        // controllers and other frameworks' controllers live in other bundles.
        guard Bundle(for: type(of: controller)) == Bundle.main else { return nil }
        if let parent = controller.parent,
           !(parent is UINavigationController || parent is UITabBarController
               || parent is UISplitViewController || parent is UIPageViewController) {
            return nil
        }
        return name(forClassName: String(describing: type(of: controller)))
    }

    static func name(forClassName className: String) -> String {
        var name = className
        for suffix in ["ViewController", "Controller"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }
}

extension UIViewController {
    /// Swapped with `viewDidAppear(_:)` by `Lemu.enableAutomaticScreenTracking()`.
    /// After the swap, calling `lemu_viewDidAppear` runs the original method.
    @objc dynamic func lemu_viewDidAppear(_ animated: Bool) {
        lemu_viewDidAppear(animated)
        LemuViewControllerTracker.viewDidAppear(self)
    }
}
#endif
