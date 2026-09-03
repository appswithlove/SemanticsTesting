//
// SemanticsTester+PullToRefresh.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import UIKit

extension SemanticsTester {
    /// Fires the `UIRefreshControl` SwiftUI's `.refreshable` installs on the hosted scroll
    /// container — the pull gesture itself has no accessibility-tree representation to drive
    /// through `SemanticsTester`. Returns `false` if no scroll container in the hierarchy has a
    /// refresh control, which is itself evidence (not proof) for the Table caveat.
    @discardableResult
    public func triggerPullToRefresh() -> Bool {
        guard let refreshControl = Self.findRefreshControl(in: window) else { return false }
        refreshControl.sendActions(for: .valueChanged)
        return true
    }

    private static func findRefreshControl(in view: UIView) -> UIRefreshControl? {
        if let scrollView = view as? UIScrollView, let refreshControl = scrollView.refreshControl {
            return refreshControl
        }
        for subview in view.subviews {
            if let found = findRefreshControl(in: subview) {
                return found
            }
        }
        return nil
    }
}
