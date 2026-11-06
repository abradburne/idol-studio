import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QueueView: View {
    private struct Deletion {
        let ids: Set<UUID>
        let title: String
    }

    @State private var jobs: [GenerationJob] = []
    @State private var format: JobFormat = .splatPLY
    @State private var detail: Detail = .standard
    @State private var inputMode: InputMode = .real
    @State private var adding = false
    @State private var error: String?
    @State private var deletion: Deletion?

    private let queue = JobQueue.shared
    private var finishedIDs: Set<UUID> { Set(jobs.filter { !$0.state.active }.map(\.id)) }

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(16)
            Divider()
            Group {
                if jobs.isEmpty {
                    ContentUnavailableView("No jobs yet", systemImage: "list.bullet",
                                           description: Text("Add images or a folder to generate them in order."))
                } else {
                    jobList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 650, minHeight: 390)
        .alert(deletion?.title ?? "Delete jobs?", isPresented: Binding(
            get: { deletion != nil },
            set: { if !$0 { deletion = nil } }
        ), presenting: deletion) { request in
            Button("Move to Trash", role: .destructive) { perform { try queue.deleteFinished(request.ids) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the jobs from the queue and moves its copies of the source images and generated files to the Trash. Original images and exported files stay where you saved them.")
        }
        .task {
            perform { try QueueWorker.startIfNeeded() }
            while !Task.isCancelled {
                do { jobs = try queue.list() }
                catch { self.error = error.localizedDescription }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
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
                Button("Clear Finished…", systemImage: "trash") {
                    let ids = finishedIDs
                    deletion = Deletion(ids: ids, title: "Clear \(ids.count) finished \(ids.count == 1 ? "job" : "jobs")?")
                }
                .disabled(finishedIDs.isEmpty)
            }
            .disabled(adding)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var jobList: some View {
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
                if !job.state.active {
                    Button {
                        deletion = Deletion(ids: [job.id], title: "Delete “\(job.name)” from the queue?")
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete \(job.name)")
                    .help("Delete job…")
                }
            }
            .padding(.vertical, 4)
            .buttonStyle(.bordered)
        }
        .listStyle(.plain)
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
