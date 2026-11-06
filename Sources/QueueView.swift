import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QueueView: View {
    @State private var jobs: [GenerationJob] = []
    @State private var format: JobFormat = .splatPLY
    @State private var detail: Detail = .standard
    @State private var inputMode: InputMode = .real
    @State private var adding = false
    @State private var error: String?

    private let queue = JobQueue.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Output", selection: $format) {
                    ForEach(JobFormat.allCases) { Text($0.label).tag($0) }
                }.fixedSize()
                if format != .meshGLB {
                    Picker("Source", selection: $inputMode) {
                        ForEach(InputMode.allCases) { Text($0.label).tag($0) }
                    }.fixedSize()
                    Picker("Detail", selection: $detail) {
                        ForEach(Detail.allCases) { Text($0.label).tag($0) }
                    }.fixedSize()
                }
                Spacer()
            }
            HStack {
                Button("Add Images…", systemImage: "photo.on.rectangle") { add(folder: false) }
                Button("Add Folder…", systemImage: "folder") { add(folder: true) }
                if adding { ProgressView().controlSize(.small) }
                Spacer()
                Text("One generation at a time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(adding)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if jobs.isEmpty {
                ContentUnavailableView("No jobs yet", systemImage: "list.bullet",
                                       description: Text("Add images or a folder to generate them in order."))
            } else {
                List(jobs.reversed()) { job in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.name).fontWeight(.medium).lineLimit(1)
                            Text(job.format.label + " · " + (job.progress?.title ?? job.state.rawValue.capitalized))
                                .font(.caption).foregroundStyle(.secondary)
                            if let fraction = job.progress?.fraction {
                                ProgressView(value: fraction).frame(maxWidth: 210)
                            }
                            if let detail = job.error {
                                Text(detail).font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        switch job.state {
                        case .queued, .running:
                            Button("Cancel") { perform { try queue.cancel(job.id) } }
                        case .failed, .cancelled:
                            Button("Retry") { perform { try queue.retry(job.id); try QueueWorker.startIfNeeded() } }
                        case .completed:
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([queue.output(job)]) }
                        case .cancelling:
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 650, minHeight: 390)
        .task {
            perform { try QueueWorker.startIfNeeded() }
            while !Task.isCancelled {
                do { jobs = try queue.list() }
                catch { self.error = error.localizedDescription }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func perform(_ work: () throws -> Void) {
        error = nil
        do {
            try work()
            jobs = try queue.list()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = !folder
        if !folder { panel.allowedContentTypes = [.image] }
        guard panel.runModal() == .OK else { return }
        let format = format
        let detail = detail
        let inputMode = inputMode
        let selected = panel.urls
        adding = true
        error = nil
        Task {
            defer { adding = false }
            do {
                let files = if folder, let url = selected.first {
                    try await Self.images(in: url)
                } else { selected }
                _ = try await queue.enqueue(files: files, format: format, detail: detail, inputMode: inputMode)
                try QueueWorker.startIfNeeded()
                jobs = try queue.list()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @concurrent
    private static func images(in folder: URL) async throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentTypeKey, .isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
            .filter { file in
                let info = try? file.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
                return info?.isRegularFile == true && info?.contentType?.conforms(to: .image) == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
