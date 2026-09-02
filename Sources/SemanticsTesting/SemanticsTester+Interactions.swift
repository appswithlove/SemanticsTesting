//
// SemanticsTester+Interactions.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SwiftUI
import UIKit

extension SemanticsTester {
    /// Set SEMANTICS_DEMO_PAUSE (seconds, via TEST_RUNNER_ env) to slow interactions
    /// down enough to watch them live on the simulator.
    private static let demoPause = ProcessInfo.processInfo.environment["SEMANTICS_DEMO_PAUSE"]
        .flatMap(TimeInterval.init) ?? 0

    private func demoPauseIfEnabled() {
        if Self.demoPause > 0 {
            pump(Self.demoPause)
        }
    }

    public func tap(_ label: String, timeout: TimeInterval = 3) throws {
        do {
            _ = try expectLabelOrValue(label, timeout: timeout)
        } catch {
            // Menu content opened from inside a presented sheet never enters the AX
            // tree: the sheet's hosting view exposes accessibilityElements, so the
            // walker never descends into the UIKit menu subtree. Drive the displayed
            // UIMenu directly (same route as activateViaMenuAction, found by walking
            // subviews instead of climbing from a visible menu-item element).
            if activateViaDisplayedMenu(title: label) {
                pump()
                demoPauseIfEnabled()
                return
            }
            throw error
        }
        demoPauseIfEnabled()
        // Several elements can share a label (e.g. context-menu clone lists);
        // prefer buttons, and fall back per candidate.
        // Exact matches first, then merged/decorated elements that merely contain the text.
        let matches = { (pool: [SemanticsNode]) -> [SemanticsNode] in
            let exact = pool.filter { $0.label == label || $0.value == label }
            return exact + pool.filter { node in
                !exact.contains(where: { $0.element === node.element })
                    && ((node.label ?? "").contains(label) || (node.value ?? "").contains(label))
            }
        }
        // A sheet or cover blocks everything behind it for a real user, so its own matches come
        // first. Without this, a label that appears both in the sheet and on the screen underneath
        // resolves to whichever the walker reached first — tapping something unreachable.
        let presentedNodes = topmostPresentedNodes
        let front = matches(presentedNodes)
        let rest = matches(nodes).filter { node in
            !front.contains(where: { $0.element === node.element })
        }
        // Partition rather than `sorted(by:)`: that predicate compares two buttons (or two
        // non-buttons) as equal, and Swift's sort is NOT stable, so it could reorder the
        // deliberate front-then-rest order above — exactly for the elements that matter.
        //
        // While a modal is up the search stops at `front`: a sheet blocks EVERY route, not just
        // the control-event one at the bottom of this chain. Restricting only that route left
        // `accessibilityActivate()` free to fire a button on the screen behind — verified by
        // SemanticsModalReachabilityTests, which failed against exactly that narrower fix.
        // `front` empty while a modal is up therefore means "no reachable match": the tap fails,
        // which is what a user pressing that spot would get.
        let ordered = presentedNodes.isEmpty ? front + rest : front
        let candidates = ordered.filter { $0.traits.contains(.button) }
            + ordered.filter { !$0.traits.contains(.button) }
        for candidate in candidates where candidate.activate() {
            pump()
            demoPauseIfEnabled()
            return
        }
        // Menu items (context-menu cells) reject accessibilityActivate(), don't react
        // to delegate selection calls, and carry no gesture recognizers — the only
        // in-process route is the UIAction behind the displayed UIMenu.
        for candidate in candidates where activateViaMenuAction(title: label, element: candidate.element) {
            pump()
            demoPauseIfEnabled()
            return
        }
        // Segmented-picker segments reject activation; drive the UISegmentedControl.
        for candidate in candidates where activateViaSegmentedControl(title: label, element: candidate.element) {
            pump()
            demoPauseIfEnabled()
            return
        }
        // Alert / confirmation-dialog buttons reject activation; run the real
        // dismiss-then-fire-handlers sequence on the presented UIAlertController.
        if activateViaAlertAction(title: label) {
            pump()
            demoPauseIfEnabled()
            return
        }
        // TextField / .searchable search bars reject activation too — the a11y
        // element wraps a UITextField (or private UISearchBarTextField subclass);
        // "tapping" it means making it first responder, same as a real touch would.
        for candidate in candidates where activateViaFirstResponder(candidate.element) {
            demoPauseIfEnabled()
            return
        }
        // SwiftUI List rows are UICollectionViewCells, and a row's NavigationLink is often an
        // invisible overlay (zero alpha keeps the List from drawing a disclosure chevron on a
        // widget), so nothing inside the row is activatable. Selecting the row through the
        // collection view's delegate is the path a real tap takes.
        for candidate in candidates where activateViaListRow(candidate) {
            pump()
            demoPauseIfEnabled()
            return
        }
        // Toolbar / nav-bar buttons — plain AND iOS 26 role-based (.confirm/.cancel) — surface
        // as _UIButtonBarButton whose only registered action is `_invokeWithRealSender:forEvent:`,
        // which ignores a synthetic event, so accessibilityActivate() refuses them. Sending the
        // control event straight to the UIControl does run the real handler.
        for candidate in candidates where activateViaControlEvent(candidate) {
            pump()
            demoPauseIfEnabled()
            return
        }
        throw SemanticsError(
            message: "No element labelled '\(label)' could be activated",
            treeDump: dump(),
        )
    }

    /// Selects the enclosing List row through its collection view's delegate.
    ///
    /// Deliberately late in `tap()`'s chain: it makes any element inside a row a way to select
    /// that row, which is true of a real tap but would otherwise mask a more specific route.
    private func activateViaListRow(_ node: SemanticsNode) -> Bool {
        guard let view = (node.element as? UIView) ?? node.owner else { return false }
        var cell: UICollectionViewCell?
        var node: UIView? = view
        while let current = node {
            if let match = current as? UICollectionViewCell {
                cell = match
                break
            }
            node = current.superview
        }
        guard let cell else { return false }
        var collectionView: UICollectionView?
        var owner: UIView? = cell.superview
        while let current = owner {
            if let match = current as? UICollectionView {
                collectionView = match
                break
            }
            owner = current.superview
        }
        guard let collectionView,
              let indexPath = collectionView.indexPath(for: cell),
              let delegate = collectionView.delegate,
              delegate.collectionView?(collectionView, shouldSelectItemAt: indexPath) ?? true
        else { return false }
        delegate.collectionView?(collectionView, didSelectItemAt: indexPath)
        return true
    }

    /// Fires a bar button's real handler by sending its control event.
    ///
    /// Last resort in `tap()`, deliberately after every element-level route: a `UITextField` must
    /// keep going through `activateViaFirstResponder` (sending it an event would not focus it), and
    /// alerts must keep their own dismiss-then-fire sequence.
    ///
    /// Note for callers: if the button's action is `Button { Task { … } }` — the common shape here —
    /// the effect lands asynchronously, so use `tapAsync` / `settle()`. A `pump()` loop blocks the
    /// MainActor and the Task never progresses, which reads as "activation did not work".
    private func activateViaControlEvent(_ node: SemanticsNode) -> Bool {
        guard node.traits.contains(.button),
              let control = node.element as? UIControl,
              !(control is UITextField),
              // sendActions does not consult the disabled state, and silently firing a disabled
              // control would invert every "stays disabled until …" assertion in the suite.
              // Both sources are checked: the suite's gating assertions read the trait, this
              // route dispatches through the control, and they must agree before it fires.
              node.isEnabled,
              control.isEnabled,
              isVisible(control),
              // A target registered for some OTHER event (a .valueChanged-only control) would
              // otherwise report success here while nothing ran — and the caller would lose the
              // tree dump that the throw path exists to provide.
              control.allTargets.contains(where: { target in
                  !(control.actions(forTarget: target, forControlEvent: .primaryActionTriggered) ?? []).isEmpty
              })
        else {
            return false
        }
        control.sendActions(for: .primaryActionTriggered)
        return true
    }

    /// Faded-out or hidden content stays in the accessibility tree — the walker prunes `isHidden`
    /// but never `alpha`, and this app has a measured case of an `.opacity(0)` badge still being
    /// announced. A user cannot press either, so neither may be fired directly.
    private func isVisible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha == 0 {
                return false
            }
            current = candidate.superview
        }
        return true
    }

    /// Taps, then lets the queued async work run.
    ///
    /// `Button { Task { await … } }` is the common shape in this app: the synchronous action
    /// fires immediately, but its Task makes no progress while `pump()` blocks the MainActor.
    /// This awaits afterwards so the effect has actually landed when the call returns.
    public func tapAsync(_ label: String, timeout: TimeInterval = 3) async throws {
        try tap(label, timeout: timeout)
        await settle()
    }

    /// Types into a text field / search bar identified by its current label
    /// (placeholder text when empty). Focuses it first if it isn't already.
    /// Fires a bar button's control event **without** the enabled check `tap()` enforces.
    ///
    /// Only for negative controls — "a disabled Fertig applies nothing". `tap()` refuses a disabled
    /// control, which is right for real interactions but makes it unable to prove that dispatching
    /// the action anyway changes nothing. Prefer `tap()` everywhere else.
    public func forceActivate(_ label: String) throws {
        guard let node = node(label) else {
            throw SemanticsError(message: "No element labelled '\(label)'", treeDump: dump())
        }
        guard let control = node.element as? UIControl else {
            throw SemanticsError(message: "'\(label)' is not a UIControl bar button", treeDump: dump())
        }
        control.sendActions(for: .primaryActionTriggered)
    }

    public func type(_ text: String, into label: String, timeout: TimeInterval = 3) throws {
        let node = try expectLabelOrValue(label, timeout: timeout)
        guard let field = Self.textField(from: node.element) else {
            throw SemanticsError(
                message: "'\(label)' is not backed by a text field",
                treeDump: dump(),
            )
        }
        if !field.isFirstResponder {
            field.becomeFirstResponder()
            pump()
        }
        field.insertText(text)
        pump(0.2)
        // Resign after typing: an input session left running republishes the NEXT hosted
        // text field as bare UIKit chrome without its SwiftUI identifier or placeholder
        // (fresh simulators readily flip the keyboard into VisionKit's camera mode, which
        // strips even more), so later lookups by id, label, or value all come up empty.
        field.resignFirstResponder()
        pump()
        demoPauseIfEnabled()
    }

    /// Climbs from an a11y element to the nearest enclosing UITextField (covers
    /// both the public UITextField/UISearchTextField and the private
    /// UISearchBarTextField that backs an inline .searchable toolbar field).
    private static func textField(from element: NSObject) -> UITextField? {
        var current = element as? UIView
        while let view = current {
            if let field = view as? UITextField {
                return field
            }
            current = view.superview
        }
        return nil
    }

    @discardableResult
    private func activateViaFirstResponder(_ element: NSObject) -> Bool {
        guard let field = Self.textField(from: element) else { return false }
        field.becomeFirstResponder()
        pump()
        return true
    }

    private func activateViaSegmentedControl(title: String, element: NSObject) -> Bool {
        var current = element as? UIView
        while let view = current {
            if let segmented = view as? UISegmentedControl {
                for index in 0 ..< segmented.numberOfSegments
                    where segmented.titleForSegment(at: index) == title
                {
                    segmented.selectedSegmentIndex = index
                    segmented.sendActions(for: .valueChanged)
                    return true
                }
                return false
            }
            current = view.superview
        }
        return false
    }

    /// SwiftUI alert buttons are custom-view interface actions: the public
    /// UIAlertAction.handler and UIInterfaceAction.handler are both nil, and
    /// accessibilityActivate is refused at every level. The real handlers (including
    /// SwiftUI's internal registration) fire only via _invokeHandlersForAction:.
    /// Order matters: coordinated-dismiss FIRST (notifies SwiftUI's presentation
    /// state), wait for completion, then invoke — otherwise a presentation triggered
    /// by the handler races the still-presented alert and is silently dropped.
    private func activateViaAlertAction(title: String) -> Bool {
        let dismissSel = NSSelectorFromString("_dismissWithAction:")
        let invokeSel = NSSelectorFromString("_invokeHandlersForAction:")
        for root in searchRoots {
            var controller = root.rootViewController?.presentedViewController
            while let current = controller {
                if let alert = current as? UIAlertController,
                   let action = alert.actions.first(where: { $0.title == title }),
                   alert.responds(to: dismissSel), alert.responds(to: invokeSel)
                {
                    // Invoke the handlers ONLY. Any manual dismissal (plain or
                    // coordinated, before or after) desyncs SwiftUI's presentation
                    // bookkeeping and follow-up presentations get dropped. When the
                    // action writes isPresented = false (the standard pattern),
                    // SwiftUI dismisses its own alert cleanly and then presents
                    // whatever the handler queued.
                    alert.perform(invokeSel, with: action)
                    let deadline = Date().addingTimeInterval(2)
                    while alert.view.window != nil, Date() < deadline {
                        pump()
                    }
                    pump(0.2)
                    return true
                }
                controller = current.presentedViewController
            }
        }
        return false
    }

    /// Finds a UIMenu anywhere in the searched windows and invokes the action with
    /// this title. Fallback for menu items that never enter the AX tree: SwiftUI
    /// Menus inside a presented sheet bridge to a HostingUIButton whose UIMenu
    /// (showsMenuAsPrimaryAction) simply does not open in-process — the actions are
    /// only reachable on the button itself.
    private func activateViaDisplayedMenu(title: String) -> Bool {
        for root in searchRoots {
            for view in Self.allSubviews(of: root) {
                let menu: UIMenu? = if let collectionView = view as? UICollectionView,
                                       let delegate = collectionView.delegate as? NSObject,
                                       delegate.responds(to: NSSelectorFromString("displayedMenu"))
                {
                    delegate.value(forKey: "displayedMenu") as? UIMenu
                } else {
                    // Only useful once the menu has been activated: SwiftUI backs
                    // Menu with a dynamic UIMenu whose children stay empty until a
                    // display resolves them.
                    (view as? UIButton)?.menu
                }
                guard let menu, let action = Self.findAction(titled: title, in: menu) else { continue }
                Self.invokeHandler(of: action)
                dismissContextMenus()
                return true
            }
        }
        return false
    }

    private static func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    /// Climbs from a menu-item element to the context-menu list view, pulls its
    /// displayed UIMenu, and invokes the matching UIAction's handler.
    private func activateViaMenuAction(title: String, element: NSObject) -> Bool {
        var current = (element as? UIView)?.superview
        while let view = current {
            if let collectionView = view as? UICollectionView,
               let delegate = collectionView.delegate as? NSObject,
               delegate.responds(to: NSSelectorFromString("displayedMenu")),
               let menu = delegate.value(forKey: "displayedMenu") as? UIMenu,
               let action = Self.findAction(titled: title, in: menu)
            {
                Self.invokeHandler(of: action)
                dismissContextMenus()
                return true
            }
            current = view.superview
        }
        return false
    }

    private static func findAction(titled title: String, in menu: UIMenu) -> UIAction? {
        for child in menu.children {
            if let action = child as? UIAction, action.title == title {
                return action
            }
            if let submenu = child as? UIMenu, let found = findAction(titled: title, in: submenu) {
                return found
            }
        }
        return nil
    }

    private static func invokeHandler(of action: UIAction) {
        typealias Handler = @convention(block) (UIAction) -> Void
        guard let block = action.value(forKey: "handler") else { return }
        unsafeBitCast(block as AnyObject, to: Handler.self)(action)
    }

    /// Invoking a handler directly bypasses UIKit's dismissal — close any open
    /// context menu so follow-up queries see the settled UI.
    private func dismissContextMenus() {
        for interaction in Self.allInteractions(in: window) {
            (interaction as? UIContextMenuInteraction)?.dismissMenu()
        }
        pump(0.2)
    }

    private static func allInteractions(in view: UIView) -> [UIInteraction] {
        view.interactions + view.subviews.flatMap { allInteractions(in: $0) }
    }
}
