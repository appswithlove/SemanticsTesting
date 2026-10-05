//
// SemanticsTesterSnapshotTests.swift
// Copyright © 2026 Apps with love AG. All rights reserved.
//

import SemanticsTesting
import SwiftUI
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct SemanticsTesterSnapshotTests {
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SemanticsTesterSnapshotTests-\(UUID().uuidString)")

    @Test func writesAPNGOfTheWindowSize() async throws {
        let tester = await SemanticsTester.make { Text("Hello") }
        defer { tester.tearDown() }
        try tester.expect("Hello")

        let url = try tester.snapshot("hello", in: folder)

        #expect(url.lastPathComponent == "hello.png")
        // Loaded from disk the image has scale 1, so its size is in pixels.
        let image = try #require(UIImage(contentsOfFile: url.path)?.cgImage)
        let scale = tester.window.traitCollection.displayScale
        #expect(CGFloat(image.width) == tester.window.bounds.width * scale)
        #expect(CGFloat(image.height) == tester.window.bounds.height * scale)
    }

    @Test func drawsTheHostedContent() async throws {
        let tester = await SemanticsTester.make { Color(red: 1, green: 0, blue: 0).ignoresSafeArea() }
        defer { tester.tearDown() }

        let url = try tester.snapshot("red", in: folder)

        let image = try #require(UIImage(contentsOfFile: url.path)?.cgImage)
        let pixel = try #require(Self.centerPixel(of: image))
        #expect(pixel.red > 200 && pixel.green < 50 && pixel.blue < 50, "center pixel \(pixel)")
    }

    private static func centerPixel(of image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        let center = CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height)
        context.draw(image, in: center)
        return (data[0], data[1], data[2])
    }
}
