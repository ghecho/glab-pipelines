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
    private let adding = State(initialValue: false)
    @FocusState private var urlFocused: Bool

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
            if adding.wrappedValue {
                HStack(spacing: 8) {
                    // AppKit draws a TextField prompt in its own color, which shows near white on the
                    // translucent panel. A Text behind the empty field matches the footer's gray.
                    TextField("URL", text: newURL.projectedValue, prompt: Text(""))
                        .background(alignment: .leading) {
                            if newURL.wrappedValue.isEmpty {
                                Text("Paste a GitLab MR, branch or pipeline URL").foregroundStyle(.secondary).allowsHitTesting(false)
                            }
                        }
                        .textFieldStyle(.plain)
                        .focusEffectDisabled()
                        .focused($urlFocused)
                        .onAppear { urlFocused = true }
                        .onSubmit(addWatched)
                        .onExitCommand(perform: closeAddField)
                        .onChange(of: newURL.wrappedValue) { badURL.wrappedValue = false }
                        .foregroundStyle(badURL.wrappedValue ? .red : .primary)
                    Button("Cancel", action: closeAddField)
                    Button("Add", action: addWatched)
                }
            }
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
                Menu {
                    Button("Watch…") { adding.wrappedValue = true }
                    Button("Refresh") { model.pollNow() }
                    Divider()
                    Toggle("Show Hidden", isOn: Binding(get: { model.prefs.showHidden }, set: { model.prefs.showHidden = $0 }))
                    Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: model.setOpensAtLogin))
                    if model.updater != nil {
                        Button("Check for Updates…") { model.checkForUpdates() }
                    }
                    Divider()
                    Button("Quit Pipelines") { NSApp.terminate(nil) }
                } label: {
                    Label("Options", systemImage: "gearshape").labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .help("Options")
            }
        }
        .padding(12)
        .frame(width: 460)
        .background(FitWindowToContent())
        .onDisappear(perform: closeAddField)
    }

    /// An invalid URL turns red and stays for 3 seconds, so you can fix it, then the field clears.
    /// A pipeline URL needs one GitLab call to find its branch, so adding is async.
    private func addWatched() {
        let text = newURL.wrappedValue
        Task {
            guard await model.addWatched(text) else {
                badURL.wrappedValue = true
                try? await Task.sleep(for: .seconds(3))
                if newURL.wrappedValue == text { newURL.wrappedValue = "" }
                return
            }
            closeAddField()
        }
    }

    private func closeAddField() {
        newURL.wrappedValue = ""
        badURL.wrappedValue = false
        adding.wrappedValue = false
    }

    private func list(_ snapshot: Snapshot) -> some View {
        let groups = ListRules.groups(
            snapshot, pinned: model.prefs.pinned, hidden: model.prefs.hidden, showHidden: model.prefs.showHidden
        )
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.title) { group in
                Text(group.title).font(.headline).foregroundStyle(group.dimmed ? .secondary : .primary)
                ForEach(group.items) { WatchItemRow(item: $0, model: model, dimmed: group.dimmed) }
                ForEach(group.errors.sorted { $0.key.label < $1.key.label }, id: \.key) { entry in
                    HStack {
                        Text(verbatim: entry.key.label).lineLimit(1)
                        Text(entry.value).foregroundStyle(.red).font(.caption)
                        Spacer()
                        Button("Remove") { model.removeWatched(entry.key) }
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

extension WatchItem {
    /// "!123 Fix the login page" for an MR, the branch name for a branch.
    var label: String {
        switch key {
        case .mergeRequest(let mr): "!\(mr.iid) \(title)"
        case .branch: title
        }
    }
}

extension ItemKey {
    /// For a row that has only a key, such as a watch that GitLab could not find.
    var label: String {
        switch self {
        case .mergeRequest(let mr): "!\(mr.iid) \(mr.project)"
        case .branch(let branch): "\(branch.branch) \(branch.project)"
        }
    }
}

struct WatchItemRow: View {
    let item: WatchItem
    let model: AppModel
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A click on the title line, the repo line or the error expands the row, like the chevron.
            // Open in Browser is in the right-click menu.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button { model.toggle(item.key) } label: {
                        Image(systemName: model.expanded.contains(item.key) ? "chevron.down" : "chevron.right")
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(item.pipeline == nil)
                    StateIcon(state: item.pipeline?.state)
                    if case .branch = item.key {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    }
                    Text(verbatim: item.label).lineLimit(1)
                    if model.prefs.pinned.contains(item.key) {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.role == .watched {
                        Button("Remove") { model.removeWatched(item.key) }
                    }
                }
                Text(verbatim: details).font(.caption).foregroundStyle(.secondary).padding(.leading, 38)
                if let error = model.rowErrors[item.key] {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.leading, 38)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if item.pipeline != nil { model.toggle(item.key) } }
            if model.expanded.contains(item.key) {
                if let detail = model.details[item.key] {
                    PipelineDetailView(item: item, detail: detail, model: model)
                } else if model.rowErrors[item.key] == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading stages…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 38)
                }
            }
        }
        // The row's empty space takes clicks too, so a right-click anywhere on the row opens the menu.
        .contentShape(Rectangle())
        .contextMenu {
            Button(model.prefs.pinned.contains(item.key) ? "Unpin" : "Pin") { model.prefs.togglePin(item.key) }
            Button(model.prefs.hidden.contains(item.key) ? "Unhide" : "Hide") { model.prefs.toggleHidden(item.key) }
            Divider()
            Button("Open in Browser") { NSWorkspace.shared.open(item.url) }
            if item.role == .watched {
                Button("Remove") { model.removeWatched(item.key) }
            }
        }
        .opacity(dimmed ? 0.55 : 1)
    }

    /// "app · jane.doe · Running: test". Only branch rows name who started the pipeline.
    private var details: String {
        [item.projectName, item.startedBy, item.pipeline.map(summary)].compactMap { $0 }.joined(separator: " · ")
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
    let item: WatchItem
    let detail: PipelineDetail
    let model: AppModel
    private let openStages = State(initialValue: Set<String>())

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if item.pipeline?.state == .failed {
                Button("Retry failed jobs") { model.retryFailed(in: item) }
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
                            if job.state == .running, let start = job.startedAt {
                                Text(start, style: .timer).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            } else if let duration = job.duration {
                                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if job.state == .failed && job.retryable {
                                Button("Retry") { model.retry(job, in: item) }
                            }
                            if job.playable {
                                Button("Run") { model.play(job, in: item) }
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
