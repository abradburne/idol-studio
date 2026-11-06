import SwiftUI

struct ModelSetupView: View {
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("LOCAL MODEL", systemImage: "circle.hexagongrid.fill")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 9) {
                Text("Set up \(model.pack.name)")
                    .font(.system(size: 29, weight: .semibold))
                Text("Download \(model.sizeLabel) once to generate \(model.pack == .idol ? "Gaussian splats" : "textured meshes") on this Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ModelControls(model: model, busy: false)
        }
        .padding(24)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.09)) }
        .padding(28)
        .tint(Color(red: 0.68, green: 0.88, blue: 0.51))
    }
}

struct StudioSettings: View {
    @ObservedObject var model: ModelStore
    @ObservedObject var meshModel: ModelStore
    @ObservedObject var studio: Studio

    var body: some View {
        Form {
            ForEach([model, meshModel], id: \.pack) { store in
                Section(store.pack.name) {
                    LabeledContent("Status", value: store.installed ? "Installed · \(store.sizeLabel)" : "Download required · \(store.sizeLabel)")
                    ModelControls(model: store, busy: studio.progress != nil)
                    Link("View the model pack", destination: store.pack.repository)
                }
            }
            Section("About Idol Studio") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Inference", value: "On-device MLX · Apple Silicon")
                LabeledContent("Exports", value: "Gaussian PLY / GLB and textured mesh GLB")
            }
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh(); meshModel.refresh() }
    }
}

private struct ModelControls: View {
    @ObservedObject var model: ModelStore
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Model location").font(.system(size: 11, weight: .semibold))
                Text(model.directory.path(percentEncoded: false))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            if let download = model.download {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: download.fraction)
                    HStack {
                        Text(download.file).lineLimit(1)
                        Spacer()
                        Text(download.detail).monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Cancel Download") { model.cancelDownload() }
                }
            } else {
                HStack {
                    if model.installed {
                        Button("Show in Finder") { model.reveal() }
                    } else {
                        Button("Download Model") { model.startDownload() }
                            .buttonStyle(.borderedProminent)
                    }
                    Menu("Location") {
                        Button("Choose Download Folder…") { model.chooseDownloadLocation() }
                        Button("Use Existing Model…") { model.chooseExistingModel() }
                        Button("Use Default Location") { model.useDefaultLocation() }
                    }
                    .fixedSize()
                }
                .disabled(busy)
            }
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
