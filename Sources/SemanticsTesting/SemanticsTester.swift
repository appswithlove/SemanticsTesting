//
// SemanticsTester.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SwiftUI
import UIKit

// MARK: - SemanticsTester

@MainActor
public final class SemanticsTester {
    /// SwiftUI only builds its accessibility node tree when the process-wide AX
    /// automation flag is on — the same flag XCUITest flips before querying.
    /// Without it, _UIHostingView.accessibilityElements is permanently [].
    private static let axAutomationEnabled: Bool = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let sym = dlsym(handle, "_AXSSetAutomationEnabled") else { return false }
        unsafeBitCast(sym, to: (@convention(c) (Int32) -> Void).self)(1)
        return true
    }()

    /// Fresh window per tester: swapping rootViewController on an already-visible
    /// window leaves an unfinished UITransitionView behind, which silently defers
    /// every later present() — sheets never appear.
    public let window: UIWindow

    /// Menus, popovers, and context menus render in NEW windows of the same scene.
    /// Queries search our window plus any window that appeared after hosting began;
    /// the host app's pre-existing windows stay excluded.
    private weak var scene: UIWindowScene?
    private let preexistingWindows: Set<ObjectIdentifier>
    /// The scene's key window before we took over — restored in tearDown so we
    /// don't leak key status to a hidden window.
    private weak var previousKeyWindow: UIWindow?

    public convenience init(@ViewBuilder _ content: () -> some View) {
        self.init(hosting: content())
    }

    /// Self-serialization across suites: Swift Testing interleaves suites on the
    /// MainActor through our own runloop pumps, and two live testers fight over the
    /// key window (flaky AX trees). A waiting tester pumps until the active one
    /// tears down; nesting through the pump is safe because test bodies are sync.
    private static var activeTesters = 0

    /// Runloop pumping blocks the MainActor, so a *suspended* async test cannot resume while
    /// another tester spins here — the spin would wait 30 s and then take the host down blaming
    /// a missing tearDown(). `makeAsync` yields instead of spinning, which lets the suspended
    /// test finish and release the gate.
    private static func awaitGate() async {
        let deadline = Date().addingTimeInterval(30)
        while activeTesters > 0, Date() < deadline {
            await Task.yield()
        }
    }

    public init(hosting view: some View) {
        precondition(Self.axAutomationEnabled, "Could not enable AX automation — semantics tree unavailable")
        // Bounded and NON-fatal. Spinning here blocks the MainActor, so if another test is
        // suspended at an await while holding a tester, its continuation cannot run and this gate
        // can never clear. Failing the precondition then took the whole host down — repeatedly,
        // reporting "0 tests" — and blamed a missing tearDown() that was not the cause.
        // Proceeding risks at worst one confused tree; the bundles run serially (Schemes.swift),
        // so it should not arise at all.
        let deadline = Date().addingTimeInterval(5)
        while Self.activeTesters > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        if Self.activeTesters > 0 {
            let hint = "use SemanticsTester.make() and the async waits, or check for a missing tearDown()"
            print("SemanticsTester: starting while \(Self.activeTesters) tester(s) are still live — \(hint)")
        }
        Self.activeTesters += 1
        UIView.setAnimationsEnabled(false)
        // In an app-hosted bundle, attach to the host app's scene — presentation
        // transitions and control-action dispatch need a live UIApplication.
        let application = UIApplication.value(forKey: "sharedApplication") as? UIApplication
        let scene = application?.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? application?.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        self.scene = scene
        // Kill any text-input session inherited from an earlier test: a leftover keyboard —
        // worst case VisionKit's scan-from-camera mode, which fresh simulators enter readily —
        // republishes the next hosted TextField as a bare UITextField without its SwiftUI
        // identifier, placeholder, or value, so nothing can find the field any more.
        scene?.windows.forEach { $0.endEditing(true) }
        preexistingWindows = Set(scene.map { $0.windows.map(ObjectIdentifier.init) } ?? [])
        previousKeyWindow = scene?.keyWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            // Host-less bundle: no scene exists to attach to (UIKit parks the window
            // in its implicit screen-based scene). Fixed size instead of the
            // deprecated UIScreen.main — tests don't need the device's real bounds.
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        }
        window.rootViewController = UIHostingController(rootView: AnyView(view))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        pump()
    }

    /// Async counterpart of `init(hosting:)`. Prefer this in `async` tests: it waits for the
    /// serialization gate by yielding rather than by blocking the MainActor.
    public static func make(@ViewBuilder _ content: () -> some View) async -> SemanticsTester {
        await awaitGate()
        return SemanticsTester(hosting: content())
    }

    /// Lets queued MainActor work run — the async counterpart of `pump(_:)`.
    ///
    /// `pump(_:)` spins `RunLoop.main.run(until:)`, which blocks the MainActor: a `Task { … }`
    /// started by a button action makes no progress during it, so `Button { Task { await … } }`
    /// (the common shape in this app) looks like it did nothing. Awaiting instead lets those
    /// jobs run. Use this whenever the effect under test crosses an await.
    public func settle(_ seconds: TimeInterval = 0.1) async {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        window.layoutIfNeeded()
    }

    /// Waits for an element, letting queued async work run between checks.
    @discardableResult
    public func expectAsync(_ label: String, timeout: TimeInterval = 3) async throws -> SemanticsNode {
        try await waitAsync(timeout: timeout, description: "node with label '\(label)'") {
            $0.label == label
        }
    }

    /// Waits until no element with this label remains, letting queued async work run.
    public func expectGoneAsync(_ label: String, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isGone(label) {
                return
            }
            await settle(0.02)
        }
        throw SemanticsError(message: "'\(label)' is still on screen", treeDump: dump())
    }

    @discardableResult
    public func waitAsync(
        timeout: TimeInterval = 3,
        description: String,
        where predicate: (SemanticsNode) -> Bool,
    ) async throws -> SemanticsNode {
        let deadline = Date().addingTimeInterval(timeout)
        let scrollAfter = Date().addingTimeInterval(min(1, timeout / 3))
        while Date() < deadline {
            if let match = nodes.first(where: predicate) {
                return match
            }
            await settle(0.02)
            if Date() > scrollAfter {
                scrollDownOneStep(pumping: false) // the loop's settle() yields; a pump here would block async work
            }
        }
        throw SemanticsError(message: "Timed out waiting for \(description)", treeDump: dump())
    }

    /// Leaves of the frontmost presented sheet/cover, if one is up.
    ///
    /// A modal makes everything behind it untouchable for a real user, but the walker still sees
    /// it: with a sheet open, two elements can share a label — the sheet's and the one behind it —
    /// and picking the wrong one silently taps something the user could not reach.
    var topmostPresentedNodes: [SemanticsNode] {
        // Menus and popovers render in their own window of the same scene, so `searchRoots` can
        // hold several windows that are each presenting. Compare them by level and take the
        // frontmost — overwriting per root would hand back whichever window iterated last.
        var presented: UIViewController?
        var frontmostLevel: UIWindow.Level?
        for root in searchRoots {
            var controller = root.rootViewController?.presentedViewController
            var deepest: UIViewController?
            while let current = controller {
                deepest = current
                controller = current.presentedViewController
            }
            guard let deepest else { continue }
            // `scene.windows` runs back-to-front, so `>=` keeps the later window of an equal level.
            if let frontmostLevel, root.windowLevel < frontmostLevel {
                continue
            }
            frontmostLevel = root.windowLevel
            presented = deepest
        }
        guard let view = presented?.viewIfLoaded else { return [] }
        return SemanticsWalker.leaves(in: view)
    }

    /// Internal, not private: the interaction fallbacks live in another file of this module.
    var searchRoots: [UIWindow] {
        guard let scene else { return [window] }
        return scene.windows.filter { !preexistingWindows.contains(ObjectIdentifier($0)) }
    }

    public func tearDown() {
        window.endEditing(true)
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        pump()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
        Self.activeTesters -= 1
    }

    // MARK: Queries

    /// Snapshot of all leaf elements in the searched windows right now (recomputed per call).
    public var nodes: [SemanticsNode] {
        searchRoots.flatMap { SemanticsWalker.leaves(in: $0) }
    }

    public func node(_ label: String) -> SemanticsNode? {
        nodes.first { $0.label == label }
    }

    public func node(id: String) -> SemanticsNode? {
        nodes.first { $0.identifier == id }
    }

    /// A SwiftUI `TextField` publishes its placeholder as the accessibility VALUE and leaves the
    /// label nil, so text entry has to be addressable that way too. (A `.searchable` field
    /// happens to set both, which is why the label-only lookup was enough until now.)
    /// Both label AND value must be absent. A SwiftUI `TextField` publishes its placeholder as
    /// the accessibility *value* and leaves `label` nil, so a label-only check would report such a
    /// field gone while it is still on screen — a vacuous pass, in the one direction where the
    /// assertion has no other evidence to fall back on.
    func isGone(_ text: String) -> Bool {
        node(text) == nil && node(value: text) == nil
    }

    public func node(value: String) -> SemanticsNode? {
        nodes.first { $0.value == value }
    }

    /// Substring match against label or value.
    ///
    /// Exact matching is often the wrong question: SwiftUI merges a container's children into a
    /// single element (a row renders as `label='Schlüssel, Wählen'`) and decorates labels
    /// (a required field renders as `Bezeichnung*`). Use this when the assertion is "this element
    /// mentions X", and keep `expect(_:)` for the cases where the whole label is known.
    public func node(containing text: String) -> SemanticsNode? {
        nodes.first { ($0.label ?? "").contains(text) || ($0.value ?? "").contains(text) }
    }

    /// Waits for an element whose label or value contains this text.
    @discardableResult
    public func expect(containing text: String, timeout: TimeInterval = 3) throws -> SemanticsNode {
        try wait(timeout: timeout, description: "node containing '\(text)'") {
            ($0.label ?? "").contains(text) || ($0.value ?? "").contains(text)
        }
    }

    /// Exact label or value, then substring — the order interactions resolve a target in.
    func firstMatch(_ text: String) -> SemanticsNode? {
        nodes.first { $0.label == text || $0.value == text } ?? node(containing: text)
    }

    /// Matches either the label or the value — what a user means by "the field showing 'Name'".
    @discardableResult
    func expectLabelOrValue(_ text: String, timeout: TimeInterval = 3) throws -> SemanticsNode {
        let deadline = Date().addingTimeInterval(timeout)
        let scrollAfter = Date().addingTimeInterval(min(1, timeout / 3))
        while Date() < deadline {
            if let match = firstMatch(text) {
                return match
            }
            pump()
            if Date() > scrollAfter {
                scrollDownOneStep()
            }
        }
        throw SemanticsError(message: "No node labelled, valued or containing '\(text)'", treeDump: dump())
    }

    public func dump() -> String {
        searchRoots.map { SemanticsWalker.dump($0) }.joined(separator: "\n")
    }

    // MARK: Waiting

    public func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits until an element with this label is on screen and returns it.
    @discardableResult
    public func expect(
        _ label: String,
        timeout: TimeInterval = 3,
    ) throws -> SemanticsNode {
        try wait(timeout: timeout, description: "node with label '\(label)'") { $0.label == label }
    }

    /// Waits until an element with this accessibility identifier is on screen.
    @discardableResult
    public func expect(
        id: String,
        timeout: TimeInterval = 3,
    ) throws -> SemanticsNode {
        try wait(timeout: timeout, description: "node with id '\(id)'") { $0.identifier == id }
    }

    /// Waits until no element with this label remains on screen.
    public func expectGone(
        _ label: String,
        timeout: TimeInterval = 3,
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isGone(label) {
                return
            }
            pump()
        }
        throw SemanticsError(message: "'\(label)' is still on screen", treeDump: dump())
    }

    @discardableResult
    public func wait(
        timeout: TimeInterval = 3,
        description: String,
        where predicate: (SemanticsNode) -> Bool,
    ) throws -> SemanticsNode {
        let deadline = Date().addingTimeInterval(timeout)
        let scrollAfter = Date().addingTimeInterval(min(1, timeout / 3))
        while Date() < deadline {
            if let match = nodes.first(where: predicate) {
                return match
            }
            pump()
            if Date() > scrollAfter {
                scrollDownOneStep()
            }
        }
        throw SemanticsError(message: "Timed out waiting for \(description)", treeDump: dump())
    }

    // MARK: Scrolling

    /// Scrolls every scrollable view down one step so rows below the fold materialize.
    ///
    /// Lazy lists publish only their materialized cells to the accessibility tree, and how much
    /// content fits a screen differs per OS — the History filter form is one page on iOS 27 but
    /// two on iOS 26, which made every below-the-fold assertion CI-only red. The waits scroll
    /// as a fallback, mirroring what a user does when they cannot see the control yet.
    /// Returns false when every scroll view is already at the bottom.
    @discardableResult
    func scrollDownOneStep(pumping: Bool = true) -> Bool {
        var moved = false
        for root in searchRoots {
            for scrollView in Self.scrollViews(in: root) {
                let bottom = scrollView.contentSize.height
                    + scrollView.adjustedContentInset.bottom
                    - scrollView.bounds.height
                guard bottom > scrollView.contentOffset.y + 1 else { continue }
                let target = min(scrollView.contentOffset.y + scrollView.bounds.height * 0.7, bottom)
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
                moved = true
            }
        }
        if moved, pumping {
            pump()
        } else if moved {
            searchRoots.forEach { $0.layoutIfNeeded() }
        }
        return moved
    }

    private static func scrollViews(in root: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view.isHidden {
                continue
            }
            if let scrollView = view as? UIScrollView {
                result.append(scrollView)
            }
            queue.append(contentsOf: view.subviews)
        }
        return result
    }
}
