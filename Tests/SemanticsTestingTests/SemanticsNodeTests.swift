//
// SemanticsNodeTests.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SemanticsTesting
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct SemanticsNodeTests {
    @Test func exposesLabelValueIdentifierAndTraits() {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Save"
        view.accessibilityValue = "ready"
        view.accessibilityIdentifier = "save-button"
        view.accessibilityTraits = [.button, .notEnabled]

        let node = SemanticsNode(element: view, depth: 0)

        #expect(node.label == "Save")
        #expect(node.value == "ready")
        #expect(node.identifier == "save-button")
        #expect(node.isEnabled == false)
        #expect(node.summary == "UIView label='Save' value='ready' id='save-button' [button] [disabled]")
    }

    @Test func customActionsAreListedAndPerformed() {
        final class Counter {
            var hits = 0
        }
        let counter = Counter()
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Delete") { _ in
                counter.hits += 1
                return true
            },
        ]
        let node = SemanticsNode(element: view, depth: 0)

        #expect(node.customActionNames == ["Delete"])
        #expect(node.performCustomAction(named: "Delete"))
        #expect(counter.hits == 1)
        #expect(node.performCustomAction(named: "Missing") == false)
        #expect(node.summary.hasSuffix("actions=[\"Delete\"]"))
    }
}
