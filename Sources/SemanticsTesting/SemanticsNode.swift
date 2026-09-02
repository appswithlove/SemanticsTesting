//
// SemanticsNode.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SwiftUI
import UIKit

// MARK: - SemanticsNode

/// One element of the rendered accessibility tree.
@MainActor
public struct SemanticsNode {
    public let element: NSObject
    public let depth: Int

    /// Nearest ancestor `UIView`. SwiftUI publishes leaves as `AccessibilityNode` objects that are
    /// neither views nor `UIAccessibilityElement`s, so an element cannot be climbed from on its
    /// own — the walker records the owner it descended through instead.
    public let owner: UIView?

    public init(element: NSObject, depth: Int, owner: UIView? = nil) {
        self.element = element
        self.depth = depth
        self.owner = owner
    }

    public var label: String? {
        element.accessibilityLabel
    }

    public var value: String? {
        element.accessibilityValue
    }

    public var traits: UIAccessibilityTraits {
        element.accessibilityTraits
    }

    public var isEnabled: Bool {
        !traits.contains(.notEnabled)
    }

    public var identifier: String? {
        if let identified = element as? UIAccessibilityIdentification {
            return identified.accessibilityIdentifier
        }
        if element.responds(to: NSSelectorFromString("accessibilityIdentifier")) {
            return element.value(forKey: "accessibilityIdentifier") as? String
        }
        return nil
    }

    public var customActionNames: [String] {
        (element.accessibilityCustomActions ?? []).map(\.name)
    }

    /// Performs the element's primary accessibility action (the "tap" equivalent).
    @discardableResult
    public func activate() -> Bool {
        element.accessibilityActivate()
    }

    @discardableResult
    public func performCustomAction(named name: String) -> Bool {
        guard let action = (element.accessibilityCustomActions ?? []).first(where: { $0.name == name }) else {
            return false
        }
        if let handler = action.actionHandler {
            return handler(action)
        }
        if let target = action.target as? NSObject {
            _ = target.perform(action.selector, with: action)
            return true
        }
        return false
    }

    /// Adjustable elements (sliders, steppers).
    public func increment() {
        element.accessibilityIncrement()
    }

    public func decrement() {
        element.accessibilityDecrement()
    }

    public var summary: String {
        var parts: [String] = [String(describing: type(of: element))]
        if let label {
            parts.append("label='\(label)'")
        }
        if let value {
            parts.append("value='\(value)'")
        }
        if let identifier, !identifier.isEmpty {
            parts.append("id='\(identifier)'")
        }
        if traits.contains(.button) {
            parts.append("[button]")
        }
        if traits.contains(.staticText) {
            parts.append("[text]")
        }
        if traits.contains(.notEnabled) {
            parts.append("[disabled]")
        }
        if !customActionNames.isEmpty {
            parts.append("actions=\(customActionNames)")
        }
        return parts.joined(separator: " ")
    }
}
