import CoreImage
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

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
    let name: String
    let title: String
    let preview: CGImage

    @concurrent
    static func read(_ url: URL) async throws -> Self {
        guard let preview = thumbnail(from: CGImageSourceCreateWithURL(url as CFURL, nil)) else {
            throw StudioError("Couldn’t open this image. Try a JPG, PNG, HEIC, or WebP.")
        }
        return Self(name: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent, preview: preview)
    }

    @concurrent
    static func readClipboard(_ data: Data) async throws -> Self {
        guard let preview = thumbnail(from: CGImageSourceCreateWithData(data as CFData, nil)) else {
            throw StudioError("Couldn’t read the clipboard image.")
        }
        return Self(name: "Pasted Image", title: "Pasted Image", preview: preview)
    }

    private static func thumbnail(from source: CGImageSource?) -> CGImage? {
        guard let source else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ] as CFDictionary)
    }

    @concurrent
    func meshPNG() async throws -> Data {
        // The engine composites alpha on white. Preserve an existing cutout.
        let input = CIImage(cgImage: preview)
        switch preview.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break
        default:
            if let alpha = CIFilter(name: "CIAreaMinimumAlpha", parameters: [kCIInputImageKey: input])?.outputImage {
                var pixel = [UInt8](repeating: 255, count: 4)
                CIContext().render(alpha, toBitmap: &pixel, rowBytes: 4, bounds: alpha.extent, format: .RGBA8, colorSpace: nil)
                if pixel[3] < 255 { return try png() }
            }
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: preview)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first, !result.allInstances.isEmpty,
              let mask = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler),
              let blend = CIFilter(name: "CIBlendWithMask", parameters: [
                kCIInputImageKey: input,
                kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: input.extent),
                kCIInputMaskImageKey: CIImage(cvPixelBuffer: mask)
              ])?.outputImage,
              let cutout = CIContext().createCGImage(blend, from: input.extent) else { return try png() }
        return try Self.png(cutout)
    }

    func png() throws -> Data { try Self.png(preview) }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw StudioError("Couldn’t prepare the source image.")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw StudioError("Couldn’t encode the image as PNG.") }
        return data as Data
    }
}

struct GenerationProgress: Sendable {
    enum Stage: Int, CaseIterable {
        case setup, image, shape, gaussians, texture, preview

        var label: String {
            switch self {
            case .setup: "Load model"
            case .image: "Prepare image"
            case .shape: "Generate shape"
            case .gaussians: "Build Gaussians"
            case .texture: "Paint textures"
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

    private func ready(model: URL, pack: ModelPack, progress: (GenerationProgress) -> Void) async throws -> Server {
        if let server, server.model == model, server.process.isRunning { return server }
        shutdown()
        guard pack.isComplete(at: model) else {
            throw StudioError("The \(pack.name) model is missing or incomplete. Check its location in Settings.")
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
                    progress(GenerationProgress("Loading \(pack.name) into memory…"))
                    let load = try requestBody("/v1/load-model", server: started, body: ["model": model.path])
                    let (data, response) = try await session.data(for: load)
                    try Self.check(response, data: data)
                    try Task.checkCancellation()
                    return started
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw StudioError("The local generation engine did not start within 30 seconds.")
        } catch {
            if server?.process === process { stop() }
            else { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    func generate(_ image: InputImage, model: URL, mode: InputMode, steps: Int, count: Int,
                  progress: (GenerationProgress) -> Void) async throws -> Splat {
        let data = try await generateGLB(image: image.png(), model: model, pack: .idol, options: [
            "mode": mode.rawValue, "steps": steps, "num_gaussians": count, "geometry": "splat"
        ], progress: progress)
        return try await Self.decodeSplat(data)
    }

    func generateMesh(_ image: InputImage, model: URL, progress: (GenerationProgress) -> Void) async throws -> TexturedMesh {
        progress(GenerationProgress("Preparing the source image…"))
        let png = try await image.meshPNG()
        try Task.checkCancellation()
        let data = try await generateGLB(image: png, model: model, pack: .hunyuan, options: [
            "texture": true
        ], progress: progress)
        return try await TexturedMesh.read(data)
    }

    private func generateGLB(image: Data, model: URL, pack: ModelPack, options: [String: Any],
                             progress: (GenerationProgress) -> Void) async throws -> Data {
        let server = try await ready(model: model, pack: pack, progress: progress)
        var body = options
        body["model"] = model.lastPathComponent
        body["image"] = image.base64EncodedString()
        body["seed"] = 42
        body["stream"] = true
        let request = try requestBody("/v1/3d/generations", server: server, body: body)
        progress(GenerationProgress("Preparing the image…", stage: .image))
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 8192 { break }
            }
            try Self.check(response, data: data)
            throw StudioError("Unexpected response from the generation engine.")
        }
        for try await line in bytes.lines where line.hasPrefix("data:") {
            try Task.checkCancellation()
            let data = Data(line.dropFirst(5).utf8)
            guard let event = try? JSONDecoder().decode(Event.self, from: data) else { continue }
            switch event.type {
            case "progress":
                progress(event.progress(for: pack))
            case "error":
                throw StudioError(event.message ?? "\(pack.name) generation failed.")
            case "complete":
                progress(GenerationProgress("Preparing the 3D preview…", stage: .preview))
                return try await Self.decodeGLB(event)
            default:
                break
            }
        }
        throw StudioError("The engine closed the connection before returning a 3D model.")
    }

    @concurrent
    private static func decodeGLB(_ event: Event) async throws -> Data {
        guard event.format == "glb", let data = event.data, let glb = Data(base64Encoded: data) else {
            throw StudioError("The engine returned an unreadable GLB.")
        }
        return glb
    }

    @concurrent
    private static func decodeSplat(_ data: Data) async throws -> Splat {
        try Splat(glb: data)
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
        guard let http = response as? HTTPURLResponse else { throw StudioError("Invalid response from the generation engine.") }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = obj?["error"] as? [String: Any]
            if error?["type"] as? String == "out_of_memory" {
                throw StudioError("There isn’t enough free memory to load this model. Close memory-heavy apps and try again.")
            }
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

        func progress(for pack: ModelPack) -> GenerationProgress {
            let completed = step ?? 0
            let steps = max(1, total ?? 1)
            let fraction = min(1, max(0, Double(completed) / Double(steps)))
            if pack == .hunyuan {
                switch stage {
                case "encode": return GenerationProgress("Encoding the image…", stage: .image)
                case "denoise": return GenerationProgress("Generating the mesh shape…", stage: .shape, fraction: fraction)
                case "volume", "mesh": return GenerationProgress("Building the mesh surface…", stage: .shape)
                default: return GenerationProgress("Painting the mesh textures…", stage: .texture)
                }
            }
            switch stage {
            case "idol-matte": return GenerationProgress("Removing the background…", stage: .image)
            case "idol-preprocess", "idol-condition": return GenerationProgress("Encoding the image…", stage: .image)
            case "idol-denoise":
                return GenerationProgress("Generating the 3D shape · step \(completed) of \(steps)",
                                          stage: .shape, fraction: fraction)
            case "idol-octree", "idol-gaussians": return GenerationProgress("Building the Gaussians…", stage: .gaussians)
            default: return GenerationProgress("Generating the splat…")
            }
        }
    }
}
