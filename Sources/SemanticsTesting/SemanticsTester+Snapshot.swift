//
// SemanticsTester+Snapshot.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import UIKit

public extension SemanticsTester {
    /// Writes the hosted window, plus any menu or popover window opened since, as `<name>.png`.
    /// Meant for looking at a view (e.g. in a PR review), not for comparing against a reference.
    ///
    /// The image covers the app's windows only: the system status bar is not part of it.
    ///
    /// - Parameter directory: target folder. Defaults to the `SNAPSHOT_DIR` environment variable
    ///   (`TEST_RUNNER_SNAPSHOT_DIR` when launching through xcodebuild), else a temp folder.
    @discardableResult
    func snapshot(_ name: String, in directory: URL? = nil) throws -> URL {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            for root in searchRoots where !root.isHidden {
                // A host-less window is not on screen, and drawHierarchy then draws nothing.
                if !root.drawHierarchy(in: root.frame, afterScreenUpdates: true) {
                    root.layer.render(in: context.cgContext)
                }
            }
        }
        let folder = directory
            ?? ProcessInfo.processInfo.environment["SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("semantics-snapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).png")
        try image.pngData()?.write(to: url)
        print("SemanticsTester: snapshot written to \(url.path)")
        return url
    }
}
