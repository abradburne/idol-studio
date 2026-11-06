import Darwin
import Foundation

@MainActor
enum QueueWorker {
    static func startIfNeeded(_ queue: JobQueue = .shared) throws {
        guard try queue.list().contains(where: { $0.state.active }),
              let lease = try queue.acquireWorker() else { return }
        close(lease)
        guard let executable = Bundle.main.executableURL else {
            throw StudioError("Couldn’t locate the Idol Studio worker.")
        }
        let worker = Process()
        worker.executableURL = executable
        worker.arguments = ["--queue-worker", queue.root.path]
        worker.standardInput = FileHandle.nullDevice
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        try worker.run()
    }

    static func run(_ queue: JobQueue) async throws {
        guard let lease = try queue.acquireWorker() else { return }
        defer {
            Engine.shared.shutdown()
            close(lease)
        }
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        termination.setEventHandler {
            MainActor.assumeIsolated {
                Engine.shared.shutdown()
                exit(0)
            }
        }
        termination.resume()
        defer { termination.cancel() }

        try queue.recoverInterruptedJobs()
        while let job = try queue.claim(worker: lease, onIdle: Engine.shared.shutdown) {
            try await perform(job, queue: queue)
        }
    }

    private static func perform(_ job: GenerationJob, queue: JobQueue) async throws {
        let generation = Task {
            let image = try await InputImage.read(queue.input(job.id))
            let store = ModelStore(pack: job.format.pack)
            let report: (GenerationProgress) -> Void = { queue.report(job.id, $0) }
            switch job.format {
            case .splatPLY, .splatGLB:
                let result = try await Engine.shared.generate(image, model: store.directory, mode: job.inputMode,
                                                             steps: job.detail.steps, count: job.detail.rawValue,
                                                             progress: report)
                try await save(result, job: job, queue: queue)
            case .meshGLB:
                let result = try await Engine.shared.generateMesh(image, model: store.directory, progress: report)
                try Task.checkCancellation()
                try result.glb.write(to: queue.output(job), options: .atomic)
            }
        }
        let monitor = Task {
            while !Task.isCancelled {
                if (try? queue.job(job.id).state) == .cancelling {
                    generation.cancel()
                    Engine.shared.shutdown()
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { monitor.cancel() }
        let result = await generation.result
        switch result {
        case .success:
            try queue.finish(job.id, error: nil)
        case .failure(let error):
            Engine.shared.shutdown()
            try queue.finish(job.id, error: error.localizedDescription)
        }
    }

    @concurrent
    private static func save(_ result: Splat, job: GenerationJob, queue: JobQueue) async throws {
        let data = job.format == .splatPLY ? result.ply() : result.glb
        try Task.checkCancellation()
        try data.write(to: queue.output(job), options: .atomic)
    }
}
