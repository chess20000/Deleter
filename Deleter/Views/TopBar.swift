import SwiftUI

/// Top bar: breadcrumb, progress, settings gear, discard button.
/// Layout/view preferences live in the settings popover (SettingsPanel).
struct TopBar: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Progress strip on the very top.
            progressStrip

            HStack(spacing: 12) {
                breadcrumbView
                Spacer(minLength: 8)
                capacityLabel
                settingsButton
                discardButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .background(.regularMaterial)
    }

    // MARK: - Settings gear

    private var settingsButton: some View {
        Button {
            showSettings.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(showSettings ? Color.theme.opacity(0.2) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            SettingsPanel(model: model)
        }
        .help("显示设置")
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressStrip: some View {
        let p = model.schedulerProgress
        // Always reserve a fixed-height strip so the layout never jumps when
        // compression starts/finishes. No spinner — it caused a visual nudge.
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(progressText(p))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 2)
                    if p.total > 0 {
                        Rectangle()
                            .fill(p.failed > 0 ? Color.orange : Color.theme)
                            .frame(width: geo.size.width * p.fraction, height: 2)
                    }
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 5)
        .padding(.bottom, 3)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(height: 22)
    }

    private func progressText(_ p: BsideScheduler.Progress) -> String {
        if p.isIdle && p.total > 0 && p.completed == p.total {
            return "已完成 \(p.completed)/\(p.total)" + (p.failed > 0 ? " · 失败 \(p.failed)" : "")
        }
        var parts: [String] = []
        parts.append("压缩 \(p.completed)/\(p.total)")
        if p.running > 0 { parts.append("进行中 \(p.running)") }
        if p.queued > 0 { parts.append("排队 \(p.queued)") }
        if p.failed > 0 { parts.append("失败 \(p.failed)") }
        if let name = p.currentName { parts.append("· \(name)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Breadcrumb

    @ViewBuilder
    private var breadcrumbView: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.element) { idx, url in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    model.navigate(to: url)
                } label: {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: idx == model.breadcrumb.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == model.breadcrumb.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("进入 \(url.lastPathComponent)")
            }
        }
    }

    // MARK: - Capacity (current / root-initial / disk free)

    private var capacityLabel: some View {
        // 40G / 50G / 128G  — current dir size / root dir size / volume free.
        let text = "\(AppModel.formatBytes(model.currentDirBytes)) / " +
                   "\(AppModel.formatBytes(model.rootDirBytes)) / " +
                   "\(AppModel.formatBytes(model.freeSpaceBytes))"
        return Text(text)
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .help("当前目录 / 根目录 / 磁盘可用空间")
    }

    // MARK: - Discard button

    private var discardButton: some View {
        let count = model.discardableCount
        return Button {
            model.discardOriginals()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "trash.fill")
                Text("丢弃原片")
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.25)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(count > 0 ? Color.theme : Color.theme.opacity(0.35))
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(count == 0 || model.isTrashing)
        .help(count == 0 ? "没有可丢弃的原片（需先标记 D 并完成压缩）" : "将 \(count) 张已生成副本的原片移到废纸篓")
    }
}
