//
// SemanticsWalkerTests.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SemanticsTesting
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct SemanticsWalkerTests {
    private func element(_ label: String, id: String? = nil) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = true
        view.accessibilityLabel = label
        view.accessibilityIdentifier = id
        return view
    }

    @Test func returnsLeavesDepthFirstWithOwner() {
        let root = UIView()
        let group = UIView()
        root.addSubview(group)
        group.addSubview(element("A"))
        root.addSubview(element("B"))

        let leaves = SemanticsWalker.leaves(in: root)

        #expect(leaves.map(\.label) == ["A", "B"])
        #expect(leaves.map(\.depth) == [2, 1])
        #expect(leaves[0].owner === leaves[0].element)
    }

    @Test func skipsHiddenViewsAndHiddenElements() {
        let root = UIView()
        let hidden = element("Hidden")
        hidden.isHidden = true
        root.addSubview(hidden)
        let container = UIView()
        container.accessibilityElementsHidden = true
        container.addSubview(element("Behind"))
        root.addSubview(container)
        root.addSubview(element("Visible"))

        #expect(SemanticsWalker.leaves(in: root).map(\.label) == ["Visible"])
    }

    @Test func prefersExplicitAccessibilityElementsOverSubviews() {
        let root = UIView()
        root.addSubview(element("Subview"))
        let explicit = UIAccessibilityElement(accessibilityContainer: root)
        explicit.accessibilityLabel = "Explicit"
        root.accessibilityElements = [explicit]

        let leaves = SemanticsWalker.leaves(in: root)

        #expect(leaves.map(\.label) == ["Explicit"])
        #expect(leaves[0].owner === root)
    }

    @Test func adoptsLabelledChromeOnlyWhenNothingBelowIsAnElement() {
        let chrome = UIView()
        chrome.accessibilityLabel = "Title"
        #expect(SemanticsWalker.leaves(in: chrome).map(\.label) == ["Title"])

        chrome.addSubview(element("Deeper"))
        #expect(SemanticsWalker.leaves(in: chrome).map(\.label) == ["Deeper"])
    }

    @Test func dumpMarksElementsChromeAndContainers() {
        let root = UIView()
        let chrome = UIView()
        chrome.accessibilityLabel = "Chrome"
        root.addSubview(chrome)
        root.addSubview(element("Leaf", id: "leaf"))

        let dump = SemanticsWalker.dump(root)
        let lines = dump.split(separator: "\n").map(String.init)

        #expect(lines[0].hasPrefix("○ UIView"))
        #expect(lines[1].hasPrefix("  ◐ UIView label='Chrome'"))
        #expect(lines[2].hasPrefix("  ● UIView label='Leaf' id='leaf'"))
    }
}
