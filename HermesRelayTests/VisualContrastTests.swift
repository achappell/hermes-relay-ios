import Foundation
import XCTest
@testable import HermesRelayIOS

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// WCAG 2.x contrast for the Night Console palette, read from the compiled
/// asset catalog so a hex edit in Assets.xcassets that breaks legibility fails
/// here instead of on a device.
final class VisualContrastTests: XCTestCase {
    private enum Appearance: String, CaseIterable {
        case light
        case dark
    }

    private typealias RGB = (red: Double, green: Double, blue: Double)

    /// WCAG AA for normal-size text.
    private let minimumTextContrast = 4.5

    private let surfaces = ["HermesCanvas", "HermesConsoleSurface", "HermesPanel", "HermesRaisedPanel"]

    /// Every ink that carries words on the surfaces above.
    private let inks = [
        "HermesPrimaryInk",
        "HermesSecondaryInk",
        "HermesLive",
        "HermesAttention",
        "HermesIdentity",
        "HermesUnavailable",
    ]

    func testInksMeetTextContrastOnEverySurfaceInBothAppearances() throws {
        for appearance in Appearance.allCases {
            for ink in inks {
                for surface in surfaces {
                    let ratio = try contrast(ink, on: surface, appearance)
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        minimumTextContrast,
                        "\(ink) on \(surface) (\(appearance.rawValue)) is \(format(ratio)):1"
                    )
                }
            }
        }
    }

    func testKeepListeningPillLabelMeetsTextContrastOnIdentityFill() throws {
        for appearance in Appearance.allCases {
            let ratio = try contrast("HermesOnIdentity", on: "HermesIdentity", appearance)
            XCTAssertGreaterThanOrEqual(
                ratio,
                minimumTextContrast,
                "Keep listening label on the identity fill (\(appearance.rawValue)) is \(format(ratio)):1"
            )
        }
    }

    func testAppearancesResolveToDifferentPalettes() throws {
        // Guards the helpers: if dark silently resolved as light, every dark
        // assertion above would be vacuous.
        let light = luminance(try resolve("HermesCanvas", .light))
        let dark = luminance(try resolve("HermesCanvas", .dark))

        XCTAssertGreaterThan(light, 0.8)
        XCTAssertLessThan(dark, 0.02)
    }

    func testLightPrimaryInkIsTheMidnightInkNotAGreenishBlack() throws {
        let ink = try resolve("HermesPrimaryInk", .light)
        let midnight = try resolve("HermesCanvas", .dark)

        XCTAssertEqual(ink.red, midnight.red, accuracy: 0.5 / 255)
        XCTAssertEqual(ink.green, midnight.green, accuracy: 0.5 / 255)
        XCTAssertEqual(ink.blue, midnight.blue, accuracy: 0.5 / 255)
    }

    // MARK: - Helpers

    private func contrast(_ foreground: String, on background: String, _ appearance: Appearance) throws -> Double {
        let first = luminance(try resolve(foreground, appearance))
        let second = luminance(try resolve(background, appearance))
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func luminance(_ color: RGB) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private func format(_ ratio: Double) -> String {
        String(format: "%.2f", ratio)
    }

    private func resolve(_ name: String, _ appearance: Appearance) throws -> RGB {
        let bundle = Bundle(for: VoiceSessionCoordinator.self)
        var resolved: RGB?

        #if canImport(UIKit)
        let style: UIUserInterfaceStyle = appearance == .dark ? .dark : .light
        let traits = UITraitCollection(userInterfaceStyle: style)
        if let color = UIColor(named: name, in: bundle, compatibleWith: traits) {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            if color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                resolved = (Double(red), Double(green), Double(blue))
            }
        }
        #elseif canImport(AppKit)
        let appearanceName: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        if let color = NSColor(named: NSColor.Name(name), bundle: bundle),
           let nsAppearance = NSAppearance(named: appearanceName) {
            nsAppearance.performAsCurrentDrawingAppearance {
                if let srgb = color.usingColorSpace(.sRGB) {
                    resolved = (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
                }
            }
        }
        #endif

        return try XCTUnwrap(resolved, "Could not resolve \(name) for \(appearance.rawValue)")
    }
}
