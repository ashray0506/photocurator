//  HanjiShell.swift
//  App frame: background, top pill tabs, Review button. Replaces the old sidebar.
//  Wire each section to your existing views via the `content` closure.

import SwiftUI

enum HanjiSection: String, CaseIterable, Identifiable {
    case albums = "Albums"   // was: Memories (+ trip albums)
    case map = "Map"         // was: World Map
    case stamps = "Stamps"   // was: Passport Stamps (on World Map)
    case people = "People"
    case review = "Review"   // was: Scan & Curate + Smart Delete (merged)

    var id: String { rawValue }
    static let tabs: [HanjiSection] = [.albums, .map, .stamps, .people]
}

struct HanjiShell<Content: View>: View {
    @AppStorage("hanji.background") private var backgroundRaw = HanjiBackground.libraryGreen.rawValue
    @Binding private var section: HanjiSection
    private let reviewCount: Int
    private let content: (HanjiSection) -> Content

    init(section: Binding<HanjiSection>,
         reviewCount: Int,
         @ViewBuilder content: @escaping (HanjiSection) -> Content) {
        self._section = section
        self.reviewCount = reviewCount
        self.content = content
    }

    private var background: HanjiBackground { HanjiBackground(rawValue: backgroundRaw) ?? .libraryGreen }

    var body: some View {
        let palette = HanjiPalette.palette(for: background)
        VStack(spacing: 0) {
            HanjiTopBar(section: $section, reviewCount: reviewCount)
            content(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.background.ignoresSafeArea())
        .foregroundStyle(palette.text)
        .font(HanjiFont.body())
        .environment(\.hanji, palette)
        .tint(palette.accent)                      // kills the system blue everywhere
        .preferredColorScheme(background.colorScheme)
        .animation(HanjiMotion.spring, value: backgroundRaw)
    }
}

struct HanjiTopBar: View {
    @Environment(\.hanji) private var p
    @Binding var section: HanjiSection
    let reviewCount: Int
    @Namespace private var pillNS

    var body: some View {
        HStack(spacing: 16) {
            // Brand
            HStack(spacing: 10) {
                Text("여")
                    .font(HanjiFont.display(13, bold: false))
                    .foregroundStyle(p.accent)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(p.accent, lineWidth: 1.5))
                Text("Yeohaeng").font(HanjiFont.display(18))
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 16)

            // Pill tabs
            HStack(spacing: 4) {
                ForEach(HanjiSection.tabs) { s in
                    let on = section == s
                    Button {
                        withAnimation(HanjiMotion.spring) { section = s }
                    } label: {
                        Text(s.rawValue)
                            .font(HanjiFont.body(14, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? p.pillOnText : p.muted)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background {
                                if on {
                                    Capsule().fill(p.pillOn)
                                        .matchedGeometryEffect(id: "pill", in: pillNS)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character(String(HanjiSection.tabs.firstIndex(of: s)! + 1))), modifiers: .command)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Capsule().fill(p.pill))

            Spacer(minLength: 16)

            // Review (the only "tidy" entry point)
            Button { withAnimation(HanjiMotion.spring) { section = .review } } label: {
                HStack(spacing: 8) {
                    Circle().fill(p.accent).frame(width: 8, height: 8)
                    Text("Review \(reviewCount.formatted())")
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .overlay(Capsule().strokeBorder(section == .review ? p.accent : p.line))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        // Leading inset clears the traffic lights when using .windowStyle(.hiddenTitleBar)
        .padding(.leading, 88)
        .padding(.trailing, 40)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(p.line).frame(height: 1) }
    }
}

/// Drop into your Settings scene.
struct HanjiAppearanceSettings: View {
    @AppStorage("hanji.background") private var backgroundRaw = HanjiBackground.libraryGreen.rawValue
    var body: some View {
        Picker("Background", selection: $backgroundRaw) {
            ForEach(HanjiBackground.allCases) { Text($0.rawValue).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
    }
}
