import Foundation
import Observation
import PipelineCore

@MainActor @Observable
final class WatchList {
    private(set) var keys: [MRKey]

    init() {
        keys = (UserDefaults.standard.stringArray(forKey: "watched") ?? [])
            .compactMap { URL(string: $0).flatMap(MRKey.init(url:)) }
    }

    func add(_ key: MRKey) {
        guard !keys.contains(key) else { return }
        keys.append(key)
        save()
    }

    func remove(_ key: MRKey) {
        keys.removeAll { $0 == key }
        save()
    }

    private func save() {
        UserDefaults.standard.set(keys.map(\.url.absoluteString), forKey: "watched")
    }
}
