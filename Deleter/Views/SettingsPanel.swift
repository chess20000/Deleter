import SwiftUI

/// Settings popover triggered by the gear button in the top bar. Collects all
/// view/layout preferences in one place.
struct SettingsPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("显示设置")
                .font(.headline)

            // Sort
            VStack(alignment: .leading, spacing: 6) {
                Text("排序方式").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { model.sortMode },
                    set: { model.setSortMode($0) }
                )) {
                    Text("按名称").tag(AppModel.SortMode.name)
                    Text("按拍摄时间").tag(AppModel.SortMode.date)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Fill mode
            VStack(alignment: .leading, spacing: 6) {
                Text("正方形填充").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $model.fillMode) {
                    Text("填充（裁剪）").tag(AppModel.FillMode.fill)
                    Text("适配（完整）").tag(AppModel.FillMode.fit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // RAW+JPG view mode
            VStack(alignment: .leading, spacing: 6) {
                Text("RAW+JPG 配对").font(.subheadline).foregroundStyle(.secondary)
                Picker("", selection: $model.viewMode) {
                    Text("合并").tag(AppModel.ViewMode.merged)
                    Text("分开").tag(AppModel.ViewMode.split)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Thumbnail size slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("缩略图大小").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(model.thumbnailSize)) pt")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Slider(value: $model.thumbnailSize, in: 80...320, step: 8) { _ in
                        model.gridColumns = 1 // force recompute via onChange
                    }
                    Image(systemName: "photo.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // Toggles
            Toggle("显示文件名", isOn: $model.showFilenames)
            Toggle("显示 RAW 格式标签（隐藏文件名时）", isOn: $model.showRawLabel)
            Toggle("方向键导航时自动滚动", isOn: $model.autoScrollOnNav)
            Toggle("点击时自动滚动", isOn: $model.autoScrollOnClick)
        }
        .padding(16)
        .frame(width: 280)
    }
}
