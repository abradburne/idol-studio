import Foundation

// This local transport exposes only queue operations. Output files stay on disk.
enum LocalMCP {
    @MainActor
    static func run() async {
        while let line = readLine() {
            do {
                let message = try JSONSerialization.jsonObject(with: Data(line.utf8))
                if let response = await respond(to: message) { try write(response) }
            } catch {
                try? write(failure(id: NSNull(), code: -32700, message: "Invalid JSON."))
            }
        }
    }

    @MainActor
    private static func respond(to message: Any) async -> [String: Any]? {
        guard let request = message as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return failure(id: NSNull(), code: -32600, message: "Invalid request.")
        }
        guard let id = request["id"] else { return nil }
        guard id is String || id is NSNumber else {
            return failure(id: NSNull(), code: -32600, message: "Invalid request ID.")
        }
        let parameters = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            let requested = parameters["protocolVersion"] as? String
            let version = requested == "2025-06-18" ? "2025-06-18" : "2025-11-25"
            result = [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "idol-studio",
                    "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                ],
                "instructions": "Queue local image files with generate_3d. Poll job_status with each job ID for progress and the output path."
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": tools]
        case "tools/call":
            guard let name = parameters["name"] as? String, tools.contains(where: { $0["name"] as? String == name }),
                  parameters["arguments"] == nil || parameters["arguments"] is [String: Any] else {
                return failure(id: id, code: -32602, message: "Unknown tool or invalid arguments.")
            }
            do {
                let output = try await call(name, parameters["arguments"] as? [String: Any] ?? [:])
                let text = try JSONSerialization.data(withJSONObject: output, options: .sortedKeys)
                result = [
                    "content": [["type": "text", "text": String(decoding: text, as: UTF8.self)]],
                    "structuredContent": output
                ]
            } catch {
                result = ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]]
            }
        default:
            return failure(id: id, code: -32601, message: "Method not found.")
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    @MainActor
    private static func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        let queue = JobQueue.shared
        if name == "generate_3d" {
            guard Set(args.keys).isSubset(of: ["image_path", "image_paths", "format", "detail", "source"]) else {
                throw StudioError("Unexpected generate_3d argument.")
            }
            let paths: [String]
            if let path = args["image_path"] as? String, args["image_paths"] == nil {
                paths = [path]
            } else if let batch = args["image_paths"] as? [String], args["image_path"] == nil {
                paths = batch
            } else {
                throw StudioError("Supply image_path or image_paths.")
            }
            guard (1...200).contains(paths.count), paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
                throw StudioError("Provide 1–200 absolute local image paths.")
            }
            let format = JobFormat(rawValue: try option("format", args, default: JobFormat.splatPLY.rawValue))
            let detailName = try option("detail", args, default: "standard")
            let detail = ["draft": Detail.draft, "standard": .standard, "high": .high][detailName]
            let inputMode = InputMode(rawValue: try option("source", args, default: InputMode.real.rawValue))
            guard let format, let detail, let inputMode else {
                throw StudioError("Invalid format, detail, or source.")
            }
            let jobs = try await queue.enqueue(files: paths.map { URL(fileURLWithPath: $0) }, format: format,
                                               detail: detail, inputMode: inputMode)
            // A launch failure must still return the IDs of jobs already saved.
            var result: [String: Any] = ["jobs": jobs.map { describe($0, queue: queue) }]
            do { try QueueWorker.startIfNeeded(queue) }
            catch { result["worker_error"] = error.localizedDescription }
            return result
        }

        guard args.count == 1, let value = args["job_id"] as? String, let id = UUID(uuidString: value) else {
            throw StudioError("Supply a valid job_id.")
        }
        let job = try name == "cancel_job" ? queue.cancel(id) : queue.job(id)
        var result = describe(job, queue: queue)
        if job.state.active {
            do { try QueueWorker.startIfNeeded(queue) }
            catch { result["worker_error"] = error.localizedDescription }
        }
        return result
    }

    private static func option(_ key: String, _ args: [String: Any], default fallback: String) throws -> String {
        guard let value = args[key] else { return fallback }
        guard let string = value as? String else { throw StudioError("\(key) must be a string.") }
        return string
    }

    private static func describe(_ job: GenerationJob, queue: JobQueue) -> [String: Any] {
        var description: [String: Any] = [
            "job_id": job.id.uuidString, "state": job.state.rawValue,
            "name": job.name, "format": job.format.rawValue
        ]
        if job.state == .completed { description["output_path"] = queue.output(job).path }
        if let progress = job.progress {
            description["stage"] = progress.title
            if let fraction = progress.fraction { description["stage_progress"] = fraction }
        }
        if let error = job.error { description["error"] = error }
        return description
    }

    private static var tools: [[String: Any]] {
        let jobSchema: [String: Any] = [
            "type": "object", "properties": ["job_id": ["type": "string", "format": "uuid"]],
            "required": ["job_id"], "additionalProperties": false
        ]
        return [
            [
                "name": "generate_3d",
                "description": "Queue one or more local images for on-device Gaussian splat or textured GLB generation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "image_path": ["type": "string", "description": "Absolute path to a local image."],
                        "image_paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 200],
                        "format": ["type": "string", "enum": JobFormat.allCases.map(\.rawValue), "default": "splat_ply"],
                        "detail": ["type": "string", "enum": ["draft", "standard", "high"], "default": "standard", "description": "Splat detail."],
                        "source": ["type": "string", "enum": ["real", "synthetic"], "default": "real", "description": "Splat image preparation."]
                    ],
                    "oneOf": [["required": ["image_path"]], ["required": ["image_paths"]]],
                    "additionalProperties": false
                ]
            ],
            ["name": "job_status", "description": "Check job progress and get the finished file’s local path.", "inputSchema": jobSchema],
            ["name": "cancel_job", "description": "Cancel a queued or running job.", "inputSchema": jobSchema]
        ]
    }

    private static func failure(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func write(_ response: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: response)
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}
