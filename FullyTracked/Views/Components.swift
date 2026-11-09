import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rects = frames(maxWidth: maxWidth, subviews: subviews)
        let height = rects.map(\.maxY).max() ?? 0
        let used = rects.map(\.maxX).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rects = frames(maxWidth: bounds.width, subviews: subviews)
        for (index, rect) in rects.enumerated() where index < subviews.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                proposal: ProposedViewSize(width: rect.width, height: rect.height)
            )
        }
    }

    private func frames(maxWidth: CGFloat, subviews: Subviews) -> [CGRect] {
        var rects: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let limit = maxWidth.isFinite ? maxWidth : .greatestFiniteMagnitude
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rects.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return rects
    }
}

struct ChipFlow<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Chip: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(15))
                .foregroundStyle(selected ? Theme.accent : Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface, in: Capsule())
                .overlay(
                    Capsule().stroke(selected ? Theme.accent : Theme.accent.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }
}

struct ChipRow: View {
    var titles: [String]
    var isSelected: (String) -> Bool
    var onTap: (String) -> Void

    var body: some View {
        ChipFlow {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                Chip(title: title, selected: isSelected(title)) {
                    onTap(title)
                }
            }
        }
    }
}

struct FieldLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Theme.font(15))
            .foregroundStyle(Theme.muted)
    }
}

struct AddRow: View {
    var placeholder: String
    @Binding var text: String
    var buttonTitle: String = "Add"
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .underlineField()
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit(action)
            Button(buttonTitle, action: action)
                .font(Theme.font(17))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
        }
    }
}

struct GearButton: View {
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct CapsuleButton: View {
    var title: String
    var filled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(15))
                .foregroundStyle(filled ? Theme.background : Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(filled ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(
                    Capsule().stroke(filled ? Theme.accent : Theme.accent.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
