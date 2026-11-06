import AppKit
import Metal
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Studio: ObservableObject {
    @Published var image: InputImage?
    @Published var mode: InputMode = .real
    @Published var detail: Detail = .standard
    @Published var progress: GenerationProgress?
    @Published var result: Splat?
    @Published var renderer: SplatRenderer?
    @Published var error: String?
    @Published var message: String?
    @Published var resetCount = 0
    @Published var importing = false
    @Published var targeted = false
    private var job: Task<Void, Never>?
    private var jobID: UUID?
    private var inputTask: Task<Void, Never>?

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        importImage { try await InputImage.read(url) }
    }

    func pasteImage(from pasteboard: NSPasteboard = .general) {
        let imageType = pasteboard.availableType(from: [.png, .tiff])
            ?? pasteboard.types?.first { UTType($0.rawValue)?.conforms(to: .image) == true }
        if let imageType, let data = pasteboard.data(forType: imageType) {
            importImage { try await InputImage.readClipboard(data) }
            return
        }

        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        if let url = files?.first(where: {
            (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true
        }) {
            open(url)
        } else {
            error = "Copy an image or an image file, then paste it here."
        }
    }

    private func importImage(_ read: @escaping () async throws -> InputImage) {
        inputTask?.cancel()
        importing = true
        error = nil
        inputTask = Task {
            defer { if !Task.isCancelled { importing = false } }
            do {
                let input = try await read()
                try Task.checkCancellation()
                cancel()
                image = input
                result = nil
                renderer = nil
                message = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func generate(model: URL) {
        guard let image, job == nil, !importing else { return }
        let id = UUID()
        jobID = id
        error = nil
        message = nil
        progress = GenerationProgress("Preparing IDOL…")
        let mode = mode
        let detail = detail
        job = Task {
            defer {
                if jobID == id {
                    job = nil
                    jobID = nil
                    progress = nil
                }
            }
            do {
                let splat = try await Engine.shared.generate(image, model: model, mode: mode, steps: detail.steps, count: detail.rawValue) {
                    if jobID == id { progress = $0 }
                }
                try Task.checkCancellation()
                guard let device = MTLCreateSystemDefaultDevice() else { throw StudioError("Metal is unavailable on this Mac.") }
                renderer = try SplatRenderer(splat: splat, device: device)
                result = splat
            } catch {
                if !Task.isCancelled {
                    Engine.shared.stop()
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        guard let job else { return }
        job.cancel()
        self.job = nil
        jobID = nil
        progress = nil
        Engine.shared.stop()
    }

    func export(_ fileExtension: String) {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .data]
        panel.nameFieldStringValue = (image?.title ?? "Idol Splat") + "." + fileExtension
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try (fileExtension == "ply" ? result.ply() : result.glb).write(to: url, options: .atomic)
                }.value
                message = "Exported \(url.lastPathComponent)"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct StudioView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var model: ModelStore
    private let ink = Color(red: 0.067, green: 0.071, blue: 0.09)
    private let accent = Color(red: 0.76, green: 0.96, blue: 0.57)
    private let rule = Color.white.opacity(0.10)

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(rule).frame(height: 1)
            HStack(spacing: 0) {
                sidebar.frame(width: 284)
                Rectangle().fill(rule).frame(width: 1)
                viewport
            }
            Rectangle().fill(rule).frame(height: 1)
            footer
        }
        .frame(minWidth: 820, minHeight: 570)
        .background(ink)
        .preferredColorScheme(.dark)
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first(where: \.isFileURL) else { return false }
            studio.open(first)
            return true
        } isTargeted: { studio.targeted = $0 }
        .overlay {
            if studio.targeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .alert("Idol Studio", isPresented: Binding(
            get: { studio.error != nil },
            set: { if !$0 { studio.error = nil } }
        )) {
            Button("OK", role: .cancel) { studio.error = nil }
        } message: {
            Text(studio.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Idol Studio").font(.system(size: 19, weight: .semibold))
                caption("IMAGE TO GAUSSIAN SPLAT")
            }
            Spacer()
            Button("Open Image…", systemImage: "photo") { studio.chooseImage() }
                .help("Choose a source image (⌘O)")
            Button("Paste Image", systemImage: "clipboard") { studio.pasteImage() }
                .keyboardShortcut("v")
                .help("Paste a source image (⌘V)")
            Menu {
                Button("Gaussian Splat (.ply)") { studio.export("ply") }
                Button("Gaussian Splat glTF (.glb)") { studio.export("glb") }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(studio.result == nil)
        }
        .padding(.horizontal, 21)
        .frame(height: 65)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            caption("01  /  INPUT")
            Button { studio.chooseImage() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.2))
                    if let input = studio.image {
                        Image(decorative: input.preview, scale: 1)
                            .resizable().scaledToFit()
                            .padding(5)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        VStack(spacing: 9) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 24, weight: .light)).foregroundStyle(accent)
                            Text("Drop or paste an image").font(.system(size: 14, weight: .medium))
                            Text("⌘V or click to browse").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 164)
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(rule) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(studio.image == nil ? "Drop or paste an image, or browse" : "Replace source image")

            if let image = studio.image {
                VStack(alignment: .leading, spacing: 4) {
                    Text(image.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(image.preview.width) × \(image.preview.height) input")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            Rectangle().fill(rule).frame(height: 1)
            caption("02  /  GENERATION")
            VStack(alignment: .leading, spacing: 10) {
                Picker("Source", selection: $studio.mode) {
                    ForEach(InputMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Photo leaves more room around the subject. Render uses a tighter crop.")
                Picker("Detail", selection: $studio.detail) {
                    ForEach(Detail.allCases) { Text($0.label).tag($0) }
                }
            }
            .disabled(studio.progress != nil)
            Spacer(minLength: 12)
            if let progress = studio.progress {
                VStack(alignment: .leading, spacing: 8) {
                    Text(progress.title).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).tint(accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(accent)
                    }
                }
            }
            Button {
                if studio.progress == nil { studio.generate(model: model.directory) }
                else { studio.cancel() }
            } label: {
                Label(studio.progress == nil ? "Generate Splat" : "Cancel Generation",
                      systemImage: studio.progress == nil ? "sparkles" : "stop.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 41)
            }
            .buttonStyle(.plain)
            .foregroundStyle(studio.progress == nil ? ink : .white)
            .background(studio.progress == nil ? accent : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .opacity(studio.image == nil ? 0.34 : 1)
            .disabled(studio.image == nil || studio.importing)
        }
        .padding(20)
        .background(Color.white.opacity(0.027))
    }

    private var viewport: some View {
        ZStack {
            if let renderer = studio.renderer {
                SplatViewer(renderer: renderer, resetCount: studio.resetCount)
            } else {
                RadialGradient(colors: [Color(red: 0.11, green: 0.13, blue: 0.17), ink], center: .center,
                               startRadius: 5, endRadius: 350)
                if let progress = studio.progress {
                    GenerationMonitor(progress: progress)
                } else {
                    VStack(spacing: 13) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 61, weight: .ultraLight))
                            .foregroundStyle(accent.opacity(0.82))
                            .padding(.bottom, 8)
                        Text("Splat viewport").font(.system(size: 23, weight: .medium))
                        Text(studio.image == nil ? "Drop or paste a photo or render to get started." : "Generate a splat to inspect it here.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            VStack {
                HStack {
                    caption("03  /  VIEWPORT")
                    Spacer()
                    if studio.renderer != nil {
                        Button("Reset View", systemImage: "arrow.counterclockwise") { studio.resetCount += 1 }
                    }
                }
                Spacer()
                if studio.renderer != nil {
                    Text("Drag to orbit   ·   Shift-drag to pan   ·   Scroll to zoom")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(.black.opacity(0.42), in: Capsule())
                        .allowsHitTesting(false)
                }
            }
            .padding(18)
        }
        .clipped()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text("IDOL · LOCAL MLX")
            Spacer()
            if let message = studio.message { Text(message).lineLimit(1) }
            else if let result = studio.result { Text("\(result.points.count.formatted()) Gaussians") }
            else { Text("Apple Silicon") }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(height: 31)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.6).foregroundStyle(.secondary)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Engine.shared.shutdown() }
}

@main
@MainActor
enum Entry {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--smoke-test" {
            Task { @MainActor in
                do {
                    let args = CommandLine.arguments
                    guard args.count >= 4 else { throw StudioError("Usage: --smoke-test IMAGE OUTPUT_DIRECTORY [STEPS] [COUNT]") }
                    let image = try await InputImage.read(URL(fileURLWithPath: args[2]))
                    let out = URL(fileURLWithPath: args[3])
                    let steps = args.count >= 5 ? Int(args[4]) ?? 6 : 6
                    let count = args.count >= 6 ? Int(args[5]) ?? 32768 : 32768
                    let model = ProcessInfo.processInfo.environment["IDOL_MODEL_DIR"]
                        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ModelStore().directory
                    let result = try await Engine.shared.generate(image, model: model, mode: .synthetic, steps: steps, count: count) {
                        print($0.title)
                    }
                    guard result.points.count == count, let device = MTLCreateSystemDefaultDevice() else {
                        throw StudioError("The smoke test received the wrong splat size or could not open Metal.")
                    }
                    _ = try SplatRenderer(splat: result, device: device)
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    try result.glb.write(to: out.appending(path: "smoke.glb"), options: .atomic)
                    try result.ply().write(to: out.appending(path: "smoke.ply"), options: .atomic)
                    print("Exported \(count) Gaussians as PLY and GLB.")
                    Engine.shared.shutdown()
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    Engine.shared.shutdown()
                    exit(1)
                }
            }
            dispatchMain()
        }
        IdolStudio.main()
    }
}

struct IdolStudio: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var studio = Studio()
    @StateObject private var model = ModelStore()

    var body: some Scene {
        Window("Idol Studio", id: "studio") {
            Group {
                if model.installed {
                    StudioView(studio: studio, model: model)
                } else {
                    ModelSetupView(model: model)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refresh()
            }
        }
        .defaultSize(width: 1030, height: 690)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { studio.chooseImage() }.keyboardShortcut("o").disabled(!model.installed)
                Button("Export PLY…") { studio.export("ply") }
                    .keyboardShortcut("e").disabled(studio.result == nil)
            }
        }
        Settings {
            StudioSettings(model: model, studio: studio)
        }
    }
}
