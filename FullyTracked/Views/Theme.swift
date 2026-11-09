import SwiftUI
import UIKit

enum Theme {
    static let background = Color(red: 18 / 255, green: 17 / 255, blue: 15 / 255)
    static let surface = Color(red: 30 / 255, green: 27 / 255, blue: 24 / 255)
    static let ink = Color(red: 244 / 255, green: 240 / 255, blue: 234 / 255)
    static let muted = Color(red: 168 / 255, green: 159 / 255, blue: 148 / 255)
    static let line = Color(red: 212 / 255, green: 184 / 255, blue: 150 / 255).opacity(0.35)
    static let accent = Color(red: 212 / 255, green: 184 / 255, blue: 150 / 255)
    static let danger = Color(red: 224 / 255, green: 160 / 255, blue: 151 / 255)

    /// styles.css sets Helvetica Neue, which ships with iOS.
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("Helvetica Neue", size: size).weight(weight)
    }

    static func applyChrome() {
        let surface = UIColor(red: 30 / 255, green: 27 / 255, blue: 24 / 255, alpha: 1)
        let accent = UIColor(red: 212 / 255, green: 184 / 255, blue: 150 / 255, alpha: 1)
        let ink = UIColor(red: 244 / 255, green: 240 / 255, blue: 234 / 255, alpha: 1)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = surface
        appearance.shadowColor = UIColor(red: 212 / 255, green: 184 / 255, blue: 150 / 255, alpha: 0.35)
        let layouts = [
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance,
        ]
        for layout in layouts {
            layout.normal.iconColor = accent
            layout.normal.titleTextAttributes = [.foregroundColor: accent]
            layout.selected.iconColor = ink
            layout.selected.titleTextAttributes = [.foregroundColor: ink]
        }
        let bar = UITabBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.tintColor = ink
        bar.unselectedItemTintColor = accent
    }
}

struct UnderlineModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.font(18))
            .foregroundStyle(Theme.ink)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
    }
}

extension View {
    func underlineField() -> some View {
        modifier(UnderlineModifier())
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(18))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.accent).frame(height: 1)
            }
            .opacity(configuration.isPressed ? 0.45 : 1)
    }
}
