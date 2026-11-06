import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum InputMode: String, CaseIterable, Identifiable, Sendable {
    case real, synthetic
    var id: Self { self }
    var label: String { self == .real ? "Photo" : "Render" }
}

enum Detail: Int, CaseIterable, Identifiable {
    case draft = 32768, standard = 262144, high = 1048576
    var id: Self { self }
    var label: String {
        switch self {
        case .draft: "Draft · 32K"
        case .standard: "Standard · 262K"
        case .high: "High · 1M"
        }
    }
    var steps: Int { self == .draft ? 20 : 50 }
}

struct InputImage: Sendable {
    let url: URL
    let preview: CGImage
    var title: String { url.deletingPathExtension().lastPathComponent }

    @concurrent
    static func read(_ url: URL) async throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary) else {
            throw StudioError("Couldn’t open this image. Try a JPG, PNG, HEIC, or WebP.")
        }
        return Self(url: url, preview: image)
    }

    func png() throws -> Data {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw StudioError("Couldn’t prepare the image for IDOL.")
        }
        CGImageDestinationAddImage(encoder, preview, nil)
        guard CGImageDestinationFinalize(encoder) else { throw StudioError("Couldn’t encode the image as PNG.") }
        return data as Data
    }
}

struct GenerationProgress: Sendable {
    enum Stage: Int, CaseIterable {
        case setup, image, shape, gaussians, preview

        var label: String {
            switch self {
            case .setup: "Load IDOL"
            case .image: "Prepare image"
            case .shape: "Generate shape"
            case .gaussians: "Build Gaussians"
            case .preview: "Open preview"
            }
        }
    }

    let title: String
    let fraction: Double?
    let stage: Stage

    init(_ title: String, stage: Stage = .setup, fraction: Double? = nil) {
        self.title = title
        self.stage = stage
        self.fraction = fraction
    }
}

@MainActor
final class Engine {
    static let shared = Engine()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1800
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    private struct Server {
        let process: Process
        let directory: URL
        let base: URL
        let key: String
        let model: URL
    }

    private var server: Server?
    private func executable() throws -> URL {
        guard let engine = Bundle.main.resourceURL?.appending(path: "Engine/mlx-serve"),
              FileManager.default.isExecutableFile(atPath: engine.path) else {
            throw StudioError("The bundled MLX engine is missing. Rebuild Idol Studio with scripts/setup.sh.")
        }
        return engine
    }

    func stop() {
        guard let old = server else { return }
        server = nil
        if old.process.isRunning { old.process.terminate() }
        let process = old.process
        let directory = old.directory
        Task {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func shutdown() {
        guard let old = server else { return }
        server = nil
        if old.process.isRunning {
            kill(old.process.processIdentifier, SIGKILL)
            old.process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: old.directory)
    }

    private func ready(model: URL, progress: (GenerationProgress) -> Void) async throws -> Server {
        if let server, server.model == model, server.process.isRunning { return server }
        stop()
        guard ModelPack.isComplete(at: model) else {
            throw StudioError("The IDOL model is missing or incomplete. Check its location in Settings.")
        }
        let engine = try executable()
        let directory = FileManager.default.temporaryDirectory.appending(path: "IdolStudio-\(UUID().uuidString)")
        let home = directory.appending(path: "home")
        let empty = directory.appending(path: "models")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let log = directory.appending(path: "engine.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let port = Int.random(in: 49152...65535)
        let key = UUID().uuidString
        let process = Process()
        process.executableURL = engine
        process.arguments = ["--serve", "--host", "127.0.0.1", "--port", String(port), "--model-dir", empty.path,
                             "--api-key-env", "IDOL_STUDIO_KEY", "--api-key-strict"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["IDOL_STUDIO_KEY"] = key
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        let started = Server(process: process, directory: directory, base: URL(string: "http://127.0.0.1:\(port)")!, key: key, model: model)
        do {
            try Task.checkCancellation()
            try process.run()
            server = started
            progress(GenerationProgress("Starting the local engine…"))
            for _ in 0..<120 {
                try Task.checkCancellation()
                guard process.isRunning else {
                    let details = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    throw StudioError("The engine quit during startup. " + details.split(separator: "\n").suffix(2).joined(separator: " "))
                }
                var request = request("/v1/models", server: started)
                request.timeoutInterval = 1
                if let (_, response) = try? await session.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    progress(GenerationProgress("Loading IDOL into memory…"))
                    let load = try requestBody("/v1/load-model", server: started, body: ["model": model.path])
                    let (data, response) = try await session.data(for: load)
                    try Self.check(response, data: data)
                    try Task.checkCancellation()
                    return started
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw StudioError("The local IDOL engine did not start within 30 seconds.")
        } catch {
            if server?.process === process { stop() }
            else { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    func generate(_ image: InputImage, model: URL, mode: InputMode, steps: Int, count: Int,
                  progress: (GenerationProgress) -> Void) async throws -> Splat {
        let server = try await ready(model: model, progress: progress)
        let request = try requestBody("/v1/3d/generations", server: server, body: [
            "model": model.lastPathComponent, "image": try image.png().base64EncodedString(), "mode": mode.rawValue,
            "steps": steps, "num_gaussians": count, "seed": 42, "geometry": "splat", "stream": true
        ])
        progress(GenerationProgress("Preparing the image…", stage: .image))
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 8192 { break }
            }
            try Self.check(response, data: data)
            throw StudioError("Unexpected response from the IDOL engine.")
        }
        for try await line in bytes.lines where line.hasPrefix("data:") {
            try Task.checkCancellation()
            let data = Data(line.dropFirst(5).utf8)
            guard let event = try? JSONDecoder().decode(Event.self, from: data) else { continue }
            switch event.type {
            case "progress":
                progress(event.progress)
            case "error":
                throw StudioError(event.message ?? "IDOL generation failed.")
            case "complete":
                progress(GenerationProgress("Preparing the 3D preview…", stage: .preview))
                return try await Self.decode(event)
            default:
                break
            }
        }
        throw StudioError("The engine closed the connection before returning a splat.")
    }

    @concurrent
    private static func decode(_ event: Event) async throws -> Splat {
        guard event.format == "glb", let data = event.data, let glb = Data(base64Encoded: data) else {
            throw StudioError("The engine returned an unreadable splat.")
        }
        return try Splat(glb: glb)
    }

    private func request(_ path: String, server: Server) -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: server.base)!)
        request.setValue("Bearer " + server.key, forHTTPHeaderField: "Authorization")
        return request
    }

    private func requestBody(_ path: String, server: Server, body: [String: Any]) throws -> URLRequest {
        var request = request(path, server: server)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw StudioError("Invalid response from the IDOL engine.") }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = obj?["error"] as? [String: Any]
            throw StudioError(error?["message"] as? String ?? obj?["message"] as? String
                              ?? "The IDOL engine returned HTTP \(http.statusCode).")
        }
    }

    private struct Event: Decodable, Sendable {
        let type: String
        let stage: String?
        let step: Int?
        let total: Int?
        let message: String?
        let format: String?
        let data: String?

        var progress: GenerationProgress {
            switch stage {
            case "idol-matte": return GenerationProgress("Removing the background…", stage: .image)
            case "idol-preprocess", "idol-condition": return GenerationProgress("Encoding the image…", stage: .image)
            case "idol-denoise":
                let completed = step ?? 0
                let steps = max(1, total ?? 1)
                return GenerationProgress("Generating the 3D shape · step \(completed) of \(steps)",
                                          stage: .shape, fraction: Double(completed) / Double(steps))
            case "idol-octree", "idol-gaussians": return GenerationProgress("Building the Gaussians…", stage: .gaussians)
            default: return GenerationProgress("Generating the splat…")
            }
        }
    }
}
