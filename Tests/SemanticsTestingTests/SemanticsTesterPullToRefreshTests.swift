//
// SemanticsTesterPullToRefreshTests.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SemanticsTesting
import SwiftUI
import Testing

// Observed: the refresh action did not run in this host-less bundle but does in app-host bundles
// (the consuming app covers it), so here we only assert whether the control was found and fired.
@Suite(.serialized)
@MainActor
struct SemanticsTesterPullToRefreshTests {
    @Test func findsTheRefreshControlOfARefreshableList() async {
        let tester = await SemanticsTester.make {
            List { Text("Row") }
                .refreshable {}
        }
        defer { tester.tearDown() }

        #expect(tester.triggerPullToRefresh())
    }

    @Test func findsTheRefreshControlOfARefreshableScrollView() async {
        let tester = await SemanticsTester.make {
            ScrollView { Text("Row") }
                .refreshable {}
        }
        defer { tester.tearDown() }

        #expect(tester.triggerPullToRefresh())
    }

    @Test func reportsAMissingRefreshControl() async {
        let tester = await SemanticsTester.make { Text("Static") }
        defer { tester.tearDown() }

        #expect(tester.triggerPullToRefresh() == false)
    }
}
