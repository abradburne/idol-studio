import AppKit
import CryptoKit
import Darwin
import Foundation
import os

@MainActor
final class ModelStore: ObservableObject {
    let pack: ModelPack
    private let defaultDirectory: URL

    @Published private(set) var directory: URL
    @Published private(set) var installed = false
    @Published private(set) var download: DownloadProgress?
    @Published var error: String?

    private let defaults: UserDefaults
    private var downloadTask: Task<Void, Never>?
    private var downloadID: UUID?
    private var preferenceKey: String { pack == .idol ? "modelDirectory" : "meshModelDirectory" }

    init(pack: ModelPack = .idol, defaults: UserDefaults = .standard) {
        self.pack = pack
        self.defaults = defaults
        defaultDirectory = URL.applicationSupportDirectory
            .appending(path: "Idol Studio/Models", directoryHint: .isDirectory)
            .appending(path: pack.folder, directoryHint: .isDirectory)
        let key = pack == .idol ? "modelDirectory" : "meshModelDirectory"
        directory = defaults.string(forKey: key).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultDirectory
        refresh()
    }

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: pack.totalBytes, countStyle: .file) }

    func refresh() {
        installed = pack.isComplete(at: directory)
    }

    func chooseDownloadLocation() {
        let panel = folderPanel(prompt: "Choose Location")
        panel.message = "Idol Studio will create an \(pack.folder) folder inside the location you choose."
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            select(url.appending(path: pack.folder, directoryHint: .isDirectory))
        }
    }

    func chooseExistingModel() {
        let panel = folderPanel(prompt: "Use Model")
        panel.message = "Select the folder that contains the model’s config.json and weight files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard pack.isComplete(at: url) else {
            error = "This folder doesn’t contain the complete \(pack.name) model pack. Choose the model folder itself, or use Download Model."
            return
        }
        select(url)
    }

    func useDefaultLocation() { select(defaultDirectory) }

    func reveal() {
        if installed { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
    }

    private func folderPanel(prompt: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel
    }

    private func select(_ url: URL) {
        guard downloadTask == nil else { return }
        directory = url.standardizedFileURL
        if directory == defaultDirectory {
            defaults.removeObject(forKey: preferenceKey)
        } else {
            defaults.set(directory.path, forKey: preferenceKey)
        }
        error = nil
        refresh()
    }

    func startDownload() {
        guard downloadTask == nil else { return }
        error = nil
        let target = directory
        let id = UUID()
        downloadID = id
        download = DownloadProgress(file: "Preparing download…", bytes: 0, total: pack.totalBytes)
        downloadTask = Task {
            defer {
                refresh()
                download = nil
                downloadTask = nil
                downloadID = nil
            }
            do {
                try await pack.install(at: target) { [self] progress in
                    guard downloadID == id, downloadTask?.isCancelled == false,
                          let current = download, progress.bytes >= current.bytes else { return }
                    download = progress
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }
}

struct DownloadProgress: Sendable {
    let file: String
    let bytes: Int64
    let total: Int64
    var fraction: Double { min(1, Double(bytes) / Double(total)) }
    var detail: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: bytes)) of \(formatter.string(fromByteCount: total))"
    }
}

enum ModelPack: Sendable {
    case idol, hunyuan

    var name: String { self == .idol ? "IDOL" : "Hunyuan3D 2.1" }
    var folder: String { self == .idol ? "Idol-MLX-Serve-fp16" : "Hunyuan3D-2.1-MLX-Serve-8bit" }
    var repository: URL { URL(string: "https://huggingface.co/ddalcu/\(folder)")! }

    private var source: URL {
        let revision = self == .idol ? "5a25e28e33cba0adc0f9ee91e6eff75fee6a5689" : "11ca09dc21a930e9861c0cd19bed0f0507fac232"
        return repository.appending(path: "resolve/\(revision)", directoryHint: .isDirectory)
    }

    private var files: [File] { self == .idol ? Self.idolFiles : Self.hunyuanFiles }

    private struct File: Sendable {
        let path: String
        let size: Int64
        let sha256: String?

        init(_ path: String, _ size: Int64, _ sha256: String? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }

        func isPresent(in directory: URL) -> Bool {
            let values = try? directory.appending(path: path).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return values?.isRegularFile == true && values?.fileSize.map(Int64.init) == size
        }
    }

    private static let idolFiles: [File] = [
        File("LICENSE", 11358),
        File("NOTICE", 657),
        File("config.json", 1359),
        File("dinov3/LICENSE.md", 7503),
        File("dinov3/config.json", 744),
        File("vae/config.json", 821),
        File("birefnet.safetensors", 444466856, "44bbc97b041f879975d0d6d538b8e66a25eb04d1f49aab40697544cdd97eaa8e"),
        File("decoder.safetensors", 118949711, "dd4ff4f02aa28816f0c09a9fdbe433dbbc8886ead00634fe316b41202fe23566"),
        File("decoder_gs.safetensors", 477846416, "21011bb21daa6d033fea43db69485a9af896138ede1fc2c4936cd2fbc0dff191"),
        File("denoiser.safetensors", 777098387, "5b3c282ce2b547fc05302475c18ca737ea509768eb98218e8066bba62be51c70"),
        File("dinov3/model.safetensors", 1682729248, "635ccb8a7a91ceeaf9b78b71a81b765d138fdd83bb2fcf568adda1608f2122da"),
        File("vae/model.safetensors", 67882866, "80447208aaf374db90e1f3cd71c638527929a05d985bed9dbbc0fb64e09fd3fe")
    ]

    private static let hunyuanFiles: [File] = [
        File("LICENSE", 17915),
        File("conditioner.safetensors", 325688080, "2d401c3f8614fd5738f8feb8bff78381296191c8f36c73ac3a2b5700f7318a91"),
        File("config.json", 471),
        File("dit.safetensors", 3242941850, "67780cf10488c71f6f3ec4b90946d2f87fcc3155eb5d0d26debb9f272e2aa9ea"),
        File("paint/LICENSE", 17915),
        File("paint/config.json", 2302),
        File("paint/dino.safetensors", 1211390571, "5f0433c25beef1d3bb05b775c45ada6a8608a2bc20a3843069526eee41242f97"),
        File("paint/unet.safetensors", 1720524204, "e1cab9acb9d9243736dd63600d65f9f9368158c3fb688515835b3415f6830ed5"),
        File("paint/unet_dual.safetensors", 1464526440, "78741c60d12e035c39af91af6321441c2878724a39633e313fe236811e7f6f6a"),
        File("paint/vae.safetensors", 167335331, "3a85a3c1a8f615782fe26e5362e649c2ec4e4e37dfe61e5415c7526e0e112211"),
        File("vae.safetensors", 227932915, "53ae311365f50724eab65b5b529c151fc0583d86639866d5619dc85b3b207574")
    ]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    func isComplete(at directory: URL) -> Bool {
        files.allSatisfy { $0.isPresent(in: directory) }
    }

    @concurrent
    func install(at directory: URL, progress: @escaping @MainActor @Sendable (DownloadProgress) -> Void) async throws {
        let manager = FileManager.default
        let missing = files.filter { !$0.isPresent(in: directory) }
        var finished = totalBytes - missing.reduce(Int64(0)) { $0 + $1.size }
        for file in missing {
            try Task.checkCancellation()
            let committed = finished
            let target = directory.appending(path: file.path)
            let folder = target.deletingLastPathComponent()
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let temporary = manager.temporaryDirectory.appending(path: "IdolDownload-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: temporary) }
            let transfer = DownloadTransfer(file: file.path, destination: temporary) { bytes in
                await progress(DownloadProgress(file: file.path, bytes: committed + min(file.size, bytes), total: totalBytes))
            }
            await progress(DownloadProgress(file: file.path, bytes: committed, total: totalBytes))
            try await transfer.download(from: source.appending(path: file.path))
            try Task.checkCancellation()
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == file.size else {
                throw StudioError("The download of \(file.path) was incomplete. Try again.")
            }
            await progress(DownloadProgress(file: "Verifying \(file.path)…", bytes: committed + file.size, total: totalBytes))
            if let expected = file.sha256, try Self.checksum(temporary) != expected {
                throw StudioError("The checksum for \(file.path) didn’t match. Try the download again.")
            }
            let staged = folder.appending(path: ".idol-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: staged) }
            try manager.moveItem(at: temporary, to: staged)
            try Task.checkCancellation()
            guard rename(staged.path, target.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            finished += file.size
        }
    }

    private static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class DownloadTransfer: NSObject, URLSessionDownloadDelegate {
    private struct State {
        var task: URLSessionDownloadTask?
        var continuation: CheckedContinuation<Void, any Error>?
        var result: Result<Void, any Error>?
        var cancelled = false
        var lastReported: Int64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let file: String
    private let destination: URL
    private let report: @Sendable (Int64) async -> Void

    init(file: String, destination: URL, report: @escaping @Sendable (Int64) async -> Void) {
        self.file = file
        self.destination = destination
        self.report = report
    }

    func download(from url: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = session.downloadTask(with: url)
                let shouldStart = state.withLock { state in
                    guard !state.cancelled else { return false }
                    state.task = task
                    state.continuation = continuation
                    return true
                }
                if shouldStart {
                    task.resume()
                } else {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let task = state.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let result = Result {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                throw StudioError("Hugging Face returned HTTP \(status) for \(file). Try the download again.")
            }
            // URLSession owns this file until the callback returns.
            try FileManager.default.moveItem(at: location, to: destination)
        }
        state.withLock { $0.result = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result) = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            state.task = nil
            return (continuation, state.result)
        }
        if let error { continuation?.resume(throwing: error) }
        else if let result { continuation?.resume(with: result) }
        else { continuation?.resume(throwing: StudioError("The download of \(file) ended before the file was saved.")) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let shouldReport = state.withLock { state in
            guard totalBytesWritten - state.lastReported >= 2 * 1024 * 1024 else { return false }
            state.lastReported = totalBytesWritten
            return true
        }
        if shouldReport { Task { await report(totalBytesWritten) } }
    }
}
