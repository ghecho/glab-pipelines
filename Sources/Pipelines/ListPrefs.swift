import Foundation
import Observation
import PipelineCore

/// Pins, hidden items and the Show Hidden switch, saved on this Mac. Keys are stored as their URLs,
/// the same way the watch list stores them.
@MainActor @Observable
final class ListPrefs {
    private(set) var pinned: Set<ItemKey>
    private(set) var hidden: Set<ItemKey>
    var showHidden: Bool {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }

    init() {
        pinned = Self.load("pinned")
        hidden = Self.load("hidden")
        showHidden = UserDefaults.standard.bool(forKey: "showHidden")
    }

    func togglePin(_ key: ItemKey) {
        if pinned.remove(key) == nil { pinned.insert(key) }
        save()
    }

    func toggleHidden(_ key: ItemKey) {
        if hidden.remove(key) == nil { hidden.insert(key) }
        save()
    }

    /// Drops keys of merged and closed MRs, so the sets do not grow without limit.
    func keep(only keys: Set<ItemKey>) {
        guard !pinned.isSubset(of: keys) || !hidden.isSubset(of: keys) else { return }
        pinned.formIntersection(keys)
        hidden.formIntersection(keys)
        save()
    }

    private func save() {
        UserDefaults.standard.set(pinned.map(\.url.absoluteString), forKey: "pinned")
        UserDefaults.standard.set(hidden.map(\.url.absoluteString), forKey: "hidden")
    }

    private static func load(_ name: String) -> Set<ItemKey> {
        Set((UserDefaults.standard.stringArray(forKey: name) ?? []).compactMap { URL(string: $0).flatMap(ItemKey.init(url:)) })
    }
}
