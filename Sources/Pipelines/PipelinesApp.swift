import PipelineCore
import SwiftUI

@main
struct PipelinesApp: App {
    // SwiftUI creates the App value once, so a plain constant keeps one model.
    private let model: AppModel

    init() {
        model = AppModel()
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        if model.snapshot == nil && model.error != nil { return "exclamationmark.triangle" }
        switch model.snapshot?.indicator {
        case .failed: return "xmark.circle.fill"
        case .blocked: return "pause.circle.fill"
        case .running: return "arrow.triangle.2.circlepath.circle"
        case .passed: return "checkmark.circle.fill"
        case .canceled, nil: return "circle.dashed"
        }
    }
}
