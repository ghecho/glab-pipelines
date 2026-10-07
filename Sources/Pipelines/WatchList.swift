import Foundation
import Observation
import PipelineCore

@MainActor @Observable
final class WatchList {
    private(set) var keys: [ItemKey]

    /// The list stores URLs, so a list saved before branch watches existed still loads.
    init() {
        keys = (UserDefaults.standard.stringArray(forKey: "watched") ?? [])
            .compactMap { URL(string: $0).flatMap(ItemKey.init(url:)) }
    }

    func add(_ key: ItemKey) {
        guard !keys.contains(key) else { return }
        keys.append(key)
        save()
    }

    func remove(_ key: ItemKey) {
        keys.removeAll { $0 == key }
        save()
    }

    private func save() {
        UserDefaults.standard.set(keys.map(\.url.absoluteString), forKey: "watched")
    }
}
