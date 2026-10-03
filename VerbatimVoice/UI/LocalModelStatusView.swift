import SwiftUI

/// Local SenseVoice model: bundled, downloaded, or missing with a download button.
/// Used in the settings pane and in the first-run window.
struct LocalModelStatusView: View {
    @ObservedObject var store: LocalModelStore
    var showsTitle = true

    var body: some View {
        LocalModelStatusRow(
            status: store.status,
            showsTitle: showsTitle,
            onDownload: { store.startDownload() },
            onCancel: { store.cancelDownload() }
        )
    }
}

/// The same row from plain inputs, so design snapshots need no download machinery.
struct LocalModelStatusRow: View {
    let status: LocalModelStore.Status
    var showsTitle = true
    /// Fill the download/retry button (the first-run window's current step).
    var prominent = false
    var onDownload: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showsTitle {
                    Text("本地模型").font(.system(size: 13, weight: .medium))
                }
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(VVColor.fgSecondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                action
            }
            if case .downloading(let progress) = status {
                ProgressTrack(fraction: progress.fraction)
            }
        }
    }

    private var summary: String {
        switch status {
        case .bundled:
            return "已内置"
        case .installed:
            return "已下载"
        case .notInstalled:
            return "未安装 · 约 \(LocalModelFiles.megabytes(LocalModelFiles.approximateTotalBytes))"
        case .downloading(let progress) where progress.receivedBytes == 0:
            return "正在连接，没有网络时会等待 · 约 \(LocalModelFiles.megabytes(progress.totalBytes))"
        case .downloading(let progress):
            let received = LocalModelFiles.megabytes(progress.receivedBytes)
            let total = LocalModelFiles.megabytes(progress.totalBytes)
            return "下载中 \(Int(progress.fraction * 100))% · \(received) / \(total)"
        case .verifying:
            return "正在校验…"
        case .failed(let kind, let message):
            return kind == .checksum ? "校验失败 · \(message)" : "下载失败 · \(message)"
        }
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .notInstalled:
            Button("下载") { onDownload() }
                .buttonStyle(VVButtonStyle(prominent: prominent))
        case .downloading:
            Button("取消") { onCancel() }
                .buttonStyle(VVButtonStyle())
        case .failed:
            Button("重试") { onDownload() }
                .buttonStyle(VVButtonStyle(prominent: prominent))
        case .bundled, .installed, .verifying:
            EmptyView()
        }
    }
}

/// 4pt progress bar in grays only: the app has no accent colour (docs/DESIGN.md §1.3).
private struct ProgressTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(VVColor.fillControl)
                Capsule().fill(VVColor.fillProminent)
                    .frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}
