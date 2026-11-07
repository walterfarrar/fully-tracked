import SwiftUI

enum Theme {
    static let background = Color(red: 247 / 255, green: 246 / 255, blue: 243 / 255)
    static let ink = Color(red: 28 / 255, green: 28 / 255, blue: 28 / 255)
    static let muted = Color(red: 138 / 255, green: 135 / 255, blue: 127 / 255)
    static let line = Color(red: 228 / 255, green: 225 / 255, blue: 219 / 255)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom("Helvetica Neue", size: size).weight(weight)
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
                Rectangle().fill(Theme.ink).frame(height: 1)
            }
            .opacity(configuration.isPressed ? 0.45 : 1)
    }
}
