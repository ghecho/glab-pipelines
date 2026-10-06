import AppKit
import PipelineCore
import SwiftUI

struct PanelView: View {
    let model: AppModel
    // The command line tools have no SwiftUIMacros plugin, so `@State` (a macro in the macOS 27 SDK)
    // does not build. SwiftUI still finds a stored `State` property.
    private let newURL = State(initialValue: "")
    private let badURL = State(initialValue: false)
    private let listHeight = State(initialValue: CGFloat(0))

    private let groups: [(title: String, role: Role)] = [("Mine", .authored), ("Watched", .watched), ("Reviewing", .reviewing)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if let snapshot = model.snapshot {
                // A ScrollView takes all the height it is offered. Measure the list and offer
                // only that, up to the screen height, so the URL field and buttons stay visible.
                ScrollView {
                    list(snapshot)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight.wrappedValue = $0 }
                }
                .frame(height: min(listHeight.wrappedValue, (NSScreen.main?.visibleFrame.height ?? 800) - 180))
            }
            Divider()
            // AppKit draws a TextField prompt in its own color, which shows near white on the
            // translucent panel. A Text behind the empty field matches the footer's gray.
            TextField("Watch an MR", text: newURL.projectedValue, prompt: Text(""))
                .background(alignment: .leading) {
                    if newURL.wrappedValue.isEmpty {
                        Text("Watch an MR: paste its GitLab URL").foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .onSubmit {
                    guard model.addWatched(newURL.wrappedValue) else {
                        badURL.wrappedValue = true
                        let rejected = newURL.wrappedValue
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            if newURL.wrappedValue == rejected { clearURLField() }
                        }
                        return
                    }
                    clearURLField()
                }
                .onChange(of: newURL.wrappedValue) { badURL.wrappedValue = false }
                .onDisappear { clearURLField() }
                .foregroundStyle(badURL.wrappedValue ? .red : .primary)
            if model.notifier.denied {
                HStack {
                    Text("Notifications are off for Pipelines.").font(.caption)
                    Button("Open System Settings") { model.notifier.openSettings() }
                }
            }
            HStack {
                if let updated = model.lastUpdated {
                    Text("Updated \(updated, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: model.setOpensAtLogin))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh") { model.pollNow() }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 460)
        .background(FitWindowToContent())
    }

    private func clearURLField() {
        newURL.wrappedValue = ""
        badURL.wrappedValue = false
    }

    private func list(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.title) { group in
                let rows = snapshot.mergeRequests.filter { $0.role == group.role }
                let errors = group.role == .watched ? snapshot.watchErrors.sorted { $0.key.iid > $1.key.iid } : []
                if !rows.isEmpty || !errors.isEmpty {
                    Text(group.title).font(.headline)
                    ForEach(rows) { MergeRequestRow(mergeRequest: $0, model: model) }
                    ForEach(errors, id: \.key) { entry in
                        HStack {
                            Text(verbatim: "!\(entry.key.iid) \(entry.key.project)").lineLimit(1)
                            Text(entry.value).foregroundStyle(.red).font(.caption)
                            Spacer()
                            Button("Remove") { model.removeWatched(entry.key) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// MenuBarExtra grows its window when the content grows, but it does not shrink it. The
/// shorter content then sits centered in a window that is still tall. This background view
/// has the size of the content, so it sets the window height to match and keeps the top edge.
private struct FitWindowToContent: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FitView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class FitView: NSView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard let window, let contentView = window.contentView else { return }
            let chrome = window.frame.height - contentView.frame.height
            let height = newSize.height + chrome
            guard abs(window.frame.height - height) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y = frame.maxY - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }
    }
}

struct MergeRequestRow: View {
    let mergeRequest: MergeRequest
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { model.toggle(mergeRequest.key) } label: {
                    Image(systemName: model.expanded.contains(mergeRequest.key) ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .disabled(mergeRequest.pipeline == nil)
                StateIcon(state: mergeRequest.pipeline?.state)
                Button { NSWorkspace.shared.open(mergeRequest.url) } label: {
                    Text(verbatim: "!\(mergeRequest.key.iid) \(mergeRequest.title)").lineLimit(1)
                }
                .buttonStyle(.plain)
                Spacer()
                if mergeRequest.role == .watched {
                    Button("Remove") { model.removeWatched(mergeRequest.key) }
                }
            }
            if let pipeline = mergeRequest.pipeline {
                Text(summary(pipeline)).font(.caption).foregroundStyle(.secondary).padding(.leading, 38)
            }
            if let error = model.rowErrors[mergeRequest.key] {
                Text(error).font(.caption).foregroundStyle(.red).padding(.leading, 38)
            }
            if model.expanded.contains(mergeRequest.key) {
                if let detail = model.details[mergeRequest.key] {
                    PipelineDetailView(mergeRequest: mergeRequest, detail: detail, model: model)
                } else if model.rowErrors[mergeRequest.key] == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading stages…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 38)
                }
            }
        }
    }

    private func summary(_ pipeline: Pipeline) -> String {
        switch pipeline.state {
        case .running:
            pipeline.stages.first { $0.state == .running }.map { "Running: \($0.name)" } ?? "Running"
        case .passed: "Passed"
        case .failed: pipeline.failedJobs.isEmpty ? "Failed" : "Failed: " + pipeline.failedJobs.joined(separator: ", ")
        case .blocked:
            (pipeline.failedJobs.isEmpty ? "" : "Failed: " + pipeline.failedJobs.joined(separator: ", ") + ". ")
                + "Waiting on " + pipeline.manualStages.joined(separator: ", ")
        case .canceled: "Canceled"
        }
    }
}

struct PipelineDetailView: View {
    let mergeRequest: MergeRequest
    let detail: PipelineDetail
    let model: AppModel
    private let openStages = State(initialValue: Set<String>())

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if mergeRequest.pipeline?.state == .failed {
                Button("Retry failed jobs") { model.retryFailed(in: mergeRequest) }
            }
            ForEach(detail.stages, id: \.name) { stage in
                Button {
                    if openStages.wrappedValue.remove(stage.name) == nil { openStages.wrappedValue.insert(stage.name) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: openStages.wrappedValue.contains(stage.name) ? "chevron.down" : "chevron.right").frame(width: 12)
                        StateIcon(state: stage.state)
                        Text(stage.name)
                    }
                }
                .buttonStyle(.plain)
                if openStages.wrappedValue.contains(stage.name) {
                    ForEach(stage.jobs) { job in
                        HStack(spacing: 6) {
                            StateIcon(state: job.state)
                            Text(job.name).lineLimit(1)
                            Spacer()
                            if let duration = job.duration {
                                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if job.state == .failed && job.retryable {
                                Button("Retry") { model.retry(job, in: mergeRequest) }
                            }
                            if job.playable {
                                Button("Run") { model.play(job, in: mergeRequest) }
                            }
                        }
                        .padding(.leading, 36)
                    }
                }
            }
        }
        .padding(.leading, 20)
    }
}

struct StateIcon: View {
    let state: PipelineState?

    var body: some View {
        switch state {
        case .running: Image(systemName: "arrow.triangle.2.circlepath.circle").foregroundStyle(.blue)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .blocked: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .canceled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case nil: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}
