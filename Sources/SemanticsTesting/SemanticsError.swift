//
// SemanticsError.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SwiftUI
import UIKit

// MARK: - SemanticsError

public struct SemanticsError: Error, CustomStringConvertible {
    let message: String
    let treeDump: String

    public var description: String {
        "\(message)\n--- accessibility tree ---\n\(treeDump)"
    }
}
