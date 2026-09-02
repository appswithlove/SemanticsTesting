//
// SemanticsTesterTests.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SemanticsTesting
import SwiftUI
import Testing

// MARK: - Fixtures

private struct CounterView: View {
    @State private var count = 0
    let enabled: Bool

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    var body: some View {
        VStack {
            Text("Count: \(count)")
            Button("Increment") { count += 1 }
                .disabled(!enabled)
            if count == 0 {
                Text("Untouched")
            }
        }
    }
}

private struct AsyncCounterView: View {
    @State private var count = 0

    var body: some View {
        VStack {
            Text("Async count: \(count)")
            Button("Load") {
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    count += 1
                }
            }
        }
    }
}

// MARK: - Tests

/// Host-less: the package tests run without a `UIApplication`, so presentation (sheets, menus,
/// popovers) and UIControl action dispatch are out of scope here. See README for the host-app
/// pattern consumers use to cover those.
@Suite(.serialized)
@MainActor
struct SemanticsTesterTests {
    @Test func findsTextByLabelIdentifierAndSubstring() throws {
        let tester = SemanticsTester {
            VStack {
                Text("Hello, world")
                Text("Tagged").accessibilityIdentifier("tagged-text")
                Toggle("Enabled", isOn: .constant(true))
            }
        }
        defer { tester.tearDown() }

        #expect(try tester.expect("Hello, world").traits.contains(.staticText))
        #expect(try tester.expect(id: "tagged-text").label == "Tagged")
        #expect(tester.node(containing: "world")?.label == "Hello, world")
        #expect(tester.node("Enabled")?.value == "1")
        #expect(tester.node(value: "1")?.label == "Enabled")
        #expect(tester.node("Nope") == nil)
    }

    @Test func tapDrivesButtonActionsAndStateUpdates() throws {
        let tester = SemanticsTester { CounterView() }
        defer { tester.tearDown() }

        try tester.expect("Count: 0")
        try tester.expect("Untouched")
        try tester.tap("Increment")
        try tester.expect("Count: 1")
        try tester.expectGone("Untouched")
    }

    @Test func tapRefusesDisabledControls() throws {
        let tester = SemanticsTester { CounterView(enabled: false) }
        defer { tester.tearDown() }

        #expect(throws: SemanticsError.self) {
            try tester.tap("Increment", timeout: 0.3)
        }
        try tester.expect("Count: 0")
    }

    @Test func missingElementThrowsWithTreeDump() throws {
        let tester = SemanticsTester { Text("Present") }
        defer { tester.tearDown() }

        let error = #expect(throws: SemanticsError.self) {
            try tester.expect("Absent", timeout: 0.2)
        }
        let description = try #require(error).description
        #expect(description.contains("Timed out waiting for node with label 'Absent'"))
        #expect(description.contains("--- accessibility tree ---"))
        #expect(description.contains("label='Present'"))
        #expect(tester.dump().contains("label='Present'"))
    }

    @Test func expectGoneFailsWhileElementRemains() throws {
        let tester = SemanticsTester { Text("Sticky") }
        defer { tester.tearDown() }

        #expect(throws: SemanticsError.self) {
            try tester.expectGone("Sticky", timeout: 0.2)
        }
    }

    @Test func asyncAPILetsQueuedTasksProgress() async throws {
        let tester = await SemanticsTester.make { AsyncCounterView() }
        defer { tester.tearDown() }

        try await tester.expectAsync("Async count: 0")
        try await tester.tapAsync("Load")
        try await tester.expectAsync("Async count: 1")
        try await tester.expectGoneAsync("Async count: 0")
    }

    @Test func waitsScrollListsToRevealRowsBelowTheFold() throws {
        let tester = SemanticsTester {
            List(0 ..< 80, id: \.self) { index in
                Text("Row \(index)")
            }
        }
        defer { tester.tearDown() }

        try tester.expect("Row 0")
        #expect(tester.node("Row 79") == nil)
        try tester.expect("Row 79", timeout: 6)
    }

    @Test func tearDownHidesWindowAndReleasesRoot() {
        let tester = SemanticsTester { Text("Bye") }

        tester.tearDown()

        #expect(tester.window.isHidden)
        #expect(tester.window.rootViewController == nil)
    }
}
