import SwiftUI

/// A playlist / channel link waiting for the user to choose videos.
struct CollectionRequest: Identifiable {
    let id = UUID()
    let url: String
    let mode: DownloadMode
    let quality: VideoQuality
}

/// One video found in a playlist or channel.
struct CollectionEntry: Identifiable, Hashable {
    let id: String
    let url: String
    let title: String
    let duration: Double?
    let thumbnail: URL?
}

/// Lists what is in a playlist or channel and downloads the ones you tick.
struct PlaylistPickerSheet: View {
    let request: CollectionRequest
    var onAdded: (Int) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var entries: [CollectionEntry] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("جاري قراءة القائمة…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                        Button("نزّل الرابط مثل ما هو") {
                            DownloadManager.shared.enqueue(request.url, mode: request.mode, quality: request.quality)
                            onAdded(1)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .navigationTitle(title.isEmpty ? "اختر الفيديوهات" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("تحميل (\(selected.count))") { downloadSelected() }
                        .disabled(selected.isEmpty)
                }
            }
        }
        .task { await load() }
    }

    private var list: some View {
        List {
            Section {
                HStack {
                    Button(selected.count == entries.count ? "إلغاء تحديد الكل" : "تحديد الكل") {
                        selected = selected.count == entries.count ? [] : Set(entries.map(\.id))
                    }
                    Spacer()
                    Text("\(entries.count) فيديو")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("كل فيديو ينزل لحاله بـ «\(request.mode.title)»" + (request.mode == .video ? " وجودة «\(request.quality.name)»." : "."))
            }
            Section {
                ForEach(entries) { entry in
                    Button {
                        if selected.contains(entry.id) {
                            selected.remove(entry.id)
                        } else {
                            selected.insert(entry.id)
                        }
                    } label: {
                        row(entry)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ entry: CollectionEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected.contains(entry.id) ? Color.accentColor : Color.secondary.opacity(0.5))
            AsyncImage(url: entry.thumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.tertiarySystemFill)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(width: 88, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let duration = entry.duration, duration > 0 {
                    Text(Formatters.duration(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        let result = await PythonEngine.shared.callAsync("list", [
            "url": request.url,
            "cookies": Paths.cookies.path,
            "limit": 300,
        ])
        loading = false
        guard result["ok"] as? Bool == true else {
            error = result["error"] as? String ?? "ما قدرت أقرأ القائمة"
            return
        }
        guard result["playlist"] as? Bool == true else {
            // not a list after all: just download it
            DownloadManager.shared.enqueue(request.url, mode: request.mode, quality: request.quality)
            onAdded(1)
            dismiss()
            return
        }
        title = result["title"] as? String ?? ""
        var seen = Set<String>()
        entries = (result["entries"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let url = raw["url"] as? String else { return nil }
            let id = (raw["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
            guard seen.insert(id).inserted else { return nil }
            return CollectionEntry(id: id, url: url,
                                   title: raw["title"] as? String ?? url,
                                   duration: (raw["duration"] as? NSNumber)?.doubleValue,
                                   thumbnail: (raw["thumbnail"] as? String).flatMap(URL.init(string:)))
        }
        if entries.isEmpty {
            error = "القائمة فاضية أو خاصة"
        } else if entries.count <= 50 {
            selected = Set(entries.map(\.id))
        }
    }

    private func downloadSelected() {
        let chosen = entries.filter { selected.contains($0.id) }
        for entry in chosen {
            DownloadManager.shared.enqueue(entry.url, mode: request.mode, quality: request.quality)
        }
        onAdded(chosen.count)
        dismiss()
    }
}
