import SwiftUI
import UIKit

struct JobCard: View {
    @EnvironmentObject private var manager: DownloadManager
    @ObservedObject var job: DownloadJob
    @State private var showDetail = false
    @State private var playing: PlayItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let uploader = job.uploader, !uploader.isEmpty {
                        Text(uploader)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if job.isActive && job.fraction == nil {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(job.status)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                actionButton
            }

            if job.phase == .downloading, let fraction = job.fraction {
                ProgressView(value: fraction)
                    .tint(.accentColor)
                    .animation(.linear(duration: 0.3), value: fraction)
            }

            if job.phase == .failed, let error = job.error {
                errorView(error)
            }

            if job.phase == .done {
                filesView
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contextMenu {
            Button {
                UIPasteboard.general.string = job.url
            } label: {
                Label("نسخ الرابط", systemImage: "doc.on.doc")
            }
            if !job.isActive {
                Button {
                    manager.retry(job)
                } label: {
                    Label("تحميل مرة ثانية", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                manager.remove(job)
            } label: {
                Label("إزالة من القائمة", systemImage: "trash")
            }
        }
        .sheet(item: $playing) { item in
            PlayerView(url: item.url)
        }
    }

    private var statusColor: Color {
        switch job.phase {
        case .failed: return .red
        case .done: return .green
        case .cancelled: return .secondary
        default: return .secondary
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
            if let url = job.thumbnail {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholderIcon
                    }
                }
            } else {
                placeholderIcon
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var placeholderIcon: some View {
        Image(systemName: job.mode == .audio ? "waveform" : "film")
            .font(.title3)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var actionButton: some View {
        if job.isActive {
            Button {
                manager.cancel(job)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إلغاء")
        } else if job.phase == .failed || job.phase == .cancelled {
            Button {
                manager.retry(job)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إعادة المحاولة")
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
            if let detail = job.errorDetail, !detail.isEmpty {
                DisclosureGroup("التفاصيل", isExpanded: $showDetail) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("نسخ التفاصيل") {
                            UIPasteboard.general.string = "\(job.url)\n\(detail)"
                        }
                        .font(.caption)
                    }
                }
                .font(.caption)
            }
        }
    }

    private var filesView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(job.files) { file in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: MediaTools.isAudio(file.url) ? "waveform" : "film")
                            .foregroundStyle(.secondary)
                        Text(file.url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if file.savedToPhotos {
                            Image(systemName: "photo.fill.on.rectangle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("محفوظ في الصور")
                        }
                        Button {
                            playing = PlayItem(url: file.url)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        ShareLink(item: file.url) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    if let note = file.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemFill)))
            }
        }
    }
}
