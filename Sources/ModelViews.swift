import SwiftUI

struct ModelSetupView: View {
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("WELCOME TO IDOL STUDIO", systemImage: "circle.hexagongrid.fill")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 9) {
                Text("Set up the IDOL model")
                    .font(.system(size: 29, weight: .semibold))
                Text("Download the \(model.sizeLabel) model pack once. Idol Studio uses it to turn images into 3D splats entirely on this Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ModelControls(model: model, busy: false)
        }
        .padding(32)
        .frame(maxWidth: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.09)) }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.067, green: 0.071, blue: 0.09))
        .preferredColorScheme(.dark)
        .tint(Color(red: 0.68, green: 0.88, blue: 0.51))
        .frame(minWidth: 660, minHeight: 450)
    }
}

struct StudioSettings: View {
    @ObservedObject var model: ModelStore
    @ObservedObject var studio: Studio

    var body: some View {
        Form {
            Section("Model storage") {
                LabeledContent("Model", value: "IDOL · MLX FP16")
                LabeledContent("Status", value: model.installed ? "Installed · \(model.sizeLabel)" : "Download required · \(model.sizeLabel)")
                ModelControls(model: model, busy: studio.progress != nil)
            }
            Section("About Idol Studio") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Inference", value: "On-device MLX · Apple Silicon")
                LabeledContent("Exports", value: "Gaussian PLY and glTF (GLB)")
                Link("View the IDOL model pack", destination: ModelStore.repository)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
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
