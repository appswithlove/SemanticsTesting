//
// SemanticsWalker.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SwiftUI
import UIKit

// MARK: - SemanticsWalker

@MainActor
public enum SemanticsWalker {
    /// Leaf accessibility elements reachable from `root`, depth-first.
    public static func leaves(in root: NSObject, depth: Int = 0, owner: UIView? = nil) -> [SemanticsNode] {
        if (root as? UIView)?.isHidden == true {
            return []
        }
        let owner = (root as? UIView) ?? owner
        if root.isAccessibilityElement {
            return [SemanticsNode(element: root, depth: depth, owner: owner)]
        }
        let below = children(of: root).flatMap { leaves(in: $0, depth: depth + 1, owner: owner) }
        // UIKit-native chrome — the navigation-bar title control and the search bar that
        // `.searchable(placement: .navigationBarDrawer)` renders — carries an accessibility
        // label but leaves `isAccessibilityElement` false, so SwiftUI publishes no node for
        // it. Adopt such a view only when nothing below it is an element: deeper nodes always
        // win, so this widens what is reachable without ever hiding a SwiftUI node.
        if below.isEmpty, isLabelled(root) {
            return [SemanticsNode(element: root, depth: depth, owner: owner)]
        }
        return below
    }

    /// True when the element would announce something to VoiceOver despite not claiming
    /// to be an accessibility element.
    private static func isLabelled(_ object: NSObject) -> Bool {
        object.accessibilityLabel?.isEmpty == false || object.accessibilityValue?.isEmpty == false
    }

    /// Child elements: explicit a11y elements > a11y container protocol > subviews.
    public static func children(of object: NSObject) -> [NSObject] {
        if object.accessibilityElementsHidden {
            return []
        }
        if let elements = object.accessibilityElements?.compactMap({ $0 as? NSObject }), !elements.isEmpty {
            return elements
        }
        let count = object.accessibilityElementCount()
        if count > 0, count != NSNotFound {
            return (0 ..< count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = object as? UIView {
            return view.subviews
        }
        return []
    }

    /// Full tree dump (containers included) for diagnostics.
    public static func dump(_ object: NSObject, depth: Int = 0) -> String {
        let indent = String(repeating: "  ", count: depth)
        let node = SemanticsNode(element: object, depth: depth)
        // ● element · ◐ labelled UIKit chrome (queryable when nothing below it is) · ○ container
        let marker = object.isAccessibilityElement ? "● " : (isLabelled(object) ? "◐ " : "○ ")
        var lines = [indent + marker + node.summary]
        if !object.isAccessibilityElement {
            lines += children(of: object).map { dump($0, depth: depth + 1) }
        }
        return lines.joined(separator: "\n")
    }
}
