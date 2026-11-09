import SwiftUI

struct CheckInChrome<Content: View>: View {
    var title: String
    @Binding var when: Date
    @Binding var error: String
    var saveTitle: String
    var canSave: Bool
    var save: () -> Void
    private let content: Content
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        when: Binding<Date>,
        error: Binding<String>,
        saveTitle: String,
        canSave: Bool = true,
        save: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _when = when
        _error = error
        self.saveTitle = saveTitle
        self.canSave = canSave
        self.save = save
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(title)
                        .font(Theme.font(24, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "When")
                    DatePicker("When", selection: $when)
                        .labelsHidden()
                        .tint(Theme.accent)
                }
                .padding(.top, 16)
                content
                if !error.isEmpty {
                    Text(error)
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if canSave {
                    Button(saveTitle, action: save)
                        .buttonStyle(QuietButtonStyle())
                        .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
