import Darwin
import Foundation
import ImageIO

enum JobFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case splatPLY = "splat_ply"
    case splatGLB = "splat_glb"
    case meshGLB = "mesh_glb"

    var id: Self { self }
    var label: String {
        switch self {
        case .splatPLY: "Gaussian splat (PLY)"
        case .splatGLB: "Gaussian splat (GLB)"
        case .meshGLB: "Textured mesh (GLB)"
        }
    }

    var pack: ModelPack { self == .meshGLB ? .hunyuan : .idol }
    var filename: String {
        switch self {
        case .splatPLY: "splat.ply"
        case .splatGLB: "splat.glb"
        case .meshGLB: "mesh.glb"
        }
    }
}

struct GenerationJob: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, running, cancelling, completed, failed, cancelled

        var active: Bool { self == .queued || self == .running || self == .cancelling }
    }

    let id: UUID
    let name: String
    let format: JobFormat
    let detail: Detail
    let inputMode: InputMode
    var state = State.queued
    var progress: GenerationProgress?
    var error: String?
}

// All queue writers take the same short-lived lock. The worker holds a separate
// lock across generation so app and MCP submissions cannot run two jobs at once.
struct JobQueue: Sendable {
    static let shared = Self(root: URL.applicationSupportDirectory.appending(path: "Idol Studio/Queue", directoryHint: .isDirectory))
    let root: URL

    private var manifest: URL { root.appending(path: "jobs.json") }
    private func folder(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func input(_ id: UUID) -> URL { folder(id).appending(path: "image") }
    func output(_ job: GenerationJob) -> URL { folder(job.id).appending(path: job.format.filename) }

    func list() throws -> [GenerationJob] {
        try withStateLock { try read() }
    }

    func job(_ id: UUID) throws -> GenerationJob {
        guard let job = try list().first(where: { $0.id == id }) else { throw StudioError("Job not found.") }
        return job
    }

    @concurrent
    func enqueue(files: [URL], format: JobFormat, detail: Detail, inputMode: InputMode) async throws -> [GenerationJob] {
        guard !files.isEmpty else { throw StudioError("Choose at least one image.") }
        let entries = files.map { GenerationJob(id: UUID(), name: $0.lastPathComponent, format: format,
                                               detail: detail, inputMode: inputMode) }
        try add(entries) { index, target in
            let file = files[index].resolvingSymlinksInPath()
            guard file.isFileURL, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw StudioError("Choose a local image file for \(file.lastPathComponent).")
            }
            guard let image = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
                throw StudioError("Couldn’t open \(file.lastPathComponent) as an image.")
            }
            try FileManager.default.copyItem(at: file, to: target)
        }
        return entries
    }

    @concurrent
    func enqueue(image: InputImage, format: JobFormat, detail: Detail, inputMode: InputMode) async throws -> GenerationJob {
        let job = GenerationJob(id: UUID(), name: image.name, format: format, detail: detail, inputMode: inputMode)
        let png = try image.png()
        try add([job]) { _, target in try png.write(to: target, options: .atomic) }
        return job
    }

    private func add(_ entries: [GenerationJob], copy: (Int, URL) throws -> Void) throws {
        do {
            for (index, job) in entries.enumerated() {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: folder(job.id), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try copy(index, input(job.id))
            }
            try withStateLock {
                try Task.checkCancellation()
                try write(read() + entries)
            }
        } catch {
            for job in entries { try? FileManager.default.removeItem(at: folder(job.id)) }
            throw error
        }
    }

    @discardableResult
    func cancel(_ id: UUID) throws -> GenerationJob {
        try update(id) { job in
            switch job.state {
            case .queued: job.state = .cancelled
            case .running: job.state = .cancelling
            default: break
            }
        }
    }

    func retry(_ id: UUID) throws {
        try withStateLock {
            var jobs = try read()
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw StudioError("Job not found.") }
            guard jobs[index].state == .failed || jobs[index].state == .cancelled else {
                throw StudioError("Only failed or cancelled jobs can be retried.")
            }
            var job = jobs.remove(at: index)
            job.state = .queued
            job.progress = nil
            job.error = nil
            jobs.append(job)
            try write(jobs)
        }
    }

    func report(_ id: UUID, _ progress: GenerationProgress) {
        _ = try? update(id) { if $0.state == .running { $0.progress = progress } }
    }

    func finish(_ id: UUID, error: String?) throws {
        _ = try update(id) { job in
            if job.state == .cancelling {
                job.state = .cancelled
                try? FileManager.default.removeItem(at: output(job))
            } else {
                job.state = error == nil ? .completed : .failed
                job.error = error
            }
            job.progress = nil
        }
    }

    func acquireWorker() throws -> Int32? {
        let fd = try openLock("worker.lock")
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw Self.posixError(code)
        }
        return fd
    }

    func recoverInterruptedJobs() throws {
        try withStateLock {
            var jobs = try read()
            var changed = false
            for index in jobs.indices {
                switch jobs[index].state {
                case .running:
                    jobs[index].state = .queued
                case .cancelling:
                    jobs[index].state = .cancelled
                    try? FileManager.default.removeItem(at: output(jobs[index]))
                default:
                    continue
                }
                jobs[index].progress = nil
                changed = true
            }
            if changed { try write(jobs) }
        }
    }

    func claim(worker: Int32, onIdle: () -> Void) throws -> GenerationJob? {
        try withStateLock {
            var jobs = try read()
            guard let index = jobs.firstIndex(where: { $0.state == .queued }) else {
                // Shut down under the state lock. A submitter can only enqueue and
                // launch a successor after this worker has released its lease.
                onIdle()
                flock(worker, LOCK_UN)
                return nil
            }
            jobs[index].state = .running
            try write(jobs)
            return jobs[index]
        }
    }

    private func update(_ id: UUID, _ mutate: (inout GenerationJob) -> Void) throws -> GenerationJob {
        try withStateLock {
            var jobs = try read()
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw StudioError("Job not found.") }
            mutate(&jobs[index])
            try write(jobs)
            return jobs[index]
        }
    }

    private func read() throws -> [GenerationJob] {
        do {
            return try JSONDecoder().decode([GenerationJob].self, from: Data(contentsOf: manifest))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    private func write(_ jobs: [GenerationJob]) throws {
        try JSONEncoder().encode(jobs).write(to: manifest, options: .atomic)
    }

    private func withStateLock<T>(_ work: () throws -> T) throws -> T {
        let fd = try openLock("state.lock")
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw Self.posixError(errno) }
        }
        return try work()
    }

    private func openLock(_ name: String) throws -> Int32 {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(root.appending(path: name).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError(errno) }
        return fd
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
