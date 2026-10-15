//  HanjiTheme.swift
//  Hanji design system: palette, fonts, environment plumbing.
//  macOS 14+ / SwiftUI.

import SwiftUI
import AppKit

// MARK: - Background choice (user setting)

enum HanjiBackground: String, CaseIterable, Identifiable {
    case libraryGreen = "Library green"
    case plaster = "Plaster"
    case ink = "Ink"

    var id: String { rawValue }

    /// Library green and Ink are dark grounds; Plaster is light.
    var colorScheme: ColorScheme { self == .plaster ? .light : .dark }
}

// MARK: - Palette

struct HanjiPalette {
    // Chrome (changes with the background setting)
    let background: Color
    let text: Color
    let muted: Color
    let line: Color
    let pill: Color
    let pillOn: Color
    let pillOnText: Color
    let accent: Color

    // Album paper (constant: the album always looks like a real cream album)
    static let paper       = Color(hex: 0xF7F5EF)
    static let paperEdge1  = Color(hex: 0xECE8DE)
    static let paperEdge2  = Color(hex: 0xE2DDD1)
    static let caption     = Color(hex: 0x4E534F)
    static let photoCorner = Color(hex: 0x2E3A34)
    static let stampInk    = Color(hex: 0xA44A26)
    static let tissue      = Color(hex: 0xFCFBF7)
    static let photoEmpty  = Color(hex: 0xDCD6C8)
    static let gutterShade = Color(red: 60 / 255, green: 50 / 255, blue: 35 / 255)

    static func palette(for bg: HanjiBackground) -> HanjiPalette {
        switch bg {
        case .libraryGreen:
            return HanjiPalette(background: Color(hex: 0x1E2A25), text: Color(hex: 0xEFEBE1),
                                muted: Color(hex: 0xAEB8B0), line: Color(hex: 0x34433C),
                                pill: Color(hex: 0x2A3832), pillOn: Color(hex: 0xEFEBE1),
                                pillOnText: Color(hex: 0x1E2A25), accent: Color(hex: 0xD98A5F))
        case .plaster:
            return HanjiPalette(background: Color(hex: 0xDAD4C8), text: Color(hex: 0x24272A),
                                muted: Color(hex: 0x52575A), line: Color(hex: 0xC4BCAE),
                                pill: Color(hex: 0xCDC6B8), pillOn: .white,
                                pillOnText: Color(hex: 0x24272A), accent: Color(hex: 0xC0643A))
        case .ink:
            return HanjiPalette(background: Color(hex: 0x16181D), text: Color(hex: 0xECEAE4),
                                muted: Color(hex: 0xA7A9AE), line: Color(hex: 0x2B2E35),
                                pill: Color(hex: 0x22252B), pillOn: Color(hex: 0xECEAE4),
                                pillOnText: Color(hex: 0x16181D), accent: Color(hex: 0xC9A15A))
        }
    }

    /// Text placed ON the accent colour (buttons). Dark ink reads on all three accents.
    static let onAccent = Color(hex: 0x1B1A17)
}

// MARK: - Environment

private struct HanjiPaletteKey: EnvironmentKey {
    static let defaultValue = HanjiPalette.palette(for: .libraryGreen)
}

extension EnvironmentValues {
    var hanji: HanjiPalette {
        get { self[HanjiPaletteKey.self] }
        set { self[HanjiPaletteKey.self] = newValue }
    }
}

// MARK: - Fonts
// Pairing A, "Travel journal" (PRD §4): Fraunces 72pt (display) + DM Mono
// (dates/counts/stamps/eyebrows) are bundled OFL fonts from Google Fonts —
// see Resources/Fonts and Info.plist's ATSApplicationFontsPath. UI text
// uses system SF Pro, never bundled. If a bundled font is somehow missing,
// these fall back to the closest system equivalent, so nothing breaks.

enum HanjiFont {
    /// Titles, captions, stat numbers — Fraunces72pt-SemiBold/Regular.
    static func display(_ size: CGFloat, bold: Bool = true) -> Font {
        let name = bold ? "Fraunces72pt-SemiBold" : "Fraunces72pt-Regular"
        if NSFont(name: name, size: size) != nil { return .custom(name, size: size) }
        return .system(size: size, weight: bold ? .semibold : .regular, design: .serif)
    }

    /// Tabs, buttons, body text, labels — system SF Pro, per §4 (not bundled).
    static func body(_ size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Dates, times, photo counts ("Spread 2 of 8"), eyebrows and stamp
    /// text ("ALBUM 07 · MAY 2025") — DMMono-Regular/Medium.
    static func mono(_ size: CGFloat = 12, medium: Bool = false) -> Font {
        let name = medium ? "DMMono-Medium" : "DMMono-Regular"
        if NSFont(name: name, size: size) != nil { return .custom(name, size: size) }
        return .system(size: size, weight: medium ? .medium : .regular, design: .monospaced)
    }
}

// MARK: - Motion

enum HanjiMotion {
    /// Page turn + tissue sweep.
    static let pageTurn = Animation.timingCurve(0.4, 0.1, 0.2, 1, duration: 0.7)
    /// Tabs, selection rings, stamps landing.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
