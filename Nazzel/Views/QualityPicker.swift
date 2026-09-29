import SwiftUI

/// The video quality list, as a sheet of our own (not a system menu), so the Arabic
/// always reads right to left and every choice can explain itself.
struct QualityPickerSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(VideoQuality.allCases) { quality in
                        Button {
                            selection = quality.rawValue
                            dismiss()
                        } label: {
                            QualityRow(quality: quality, selected: quality.rawValue == selection)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    if !DeviceCaps.av1 {
                        Text("فيديوهات يوتيوب بدقة 4K تحتاج آيفون 15 برو أو أحدث عشان تشتغل. جهازك بينزّل أعلى جودة يقدر يشغّلها.")
                    } else {
                        Text("لو الفيديو ما عنده الجودة اللي اخترتها، ينزل أقرب جودة لها.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("جودة الفيديو")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct QualityRow: View {
    let quality: VideoQuality
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(quality.name)
                        .font(.body.weight(.semibold))
                    Text(quality.resolution)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        .foregroundStyle(Color.accentColor)
                }
                Text(quality.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
