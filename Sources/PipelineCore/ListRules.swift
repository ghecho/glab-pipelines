public struct ListGroup: Equatable, Sendable {
    public let title: String
    public let items: [WatchItem]
    /// Watched items that GitLab returned no data for. Only the Watched group has them.
    public let errors: [ItemKey: String]
    /// The Hidden group draws its rows in gray.
    public let dimmed: Bool

    public init(title: String, items: [WatchItem], errors: [ItemKey: String], dimmed: Bool) {
        self.title = title
        self.items = items
        self.errors = errors
        self.dimmed = dimmed
    }
}

public enum ListRules {
    /// Pinned on top, then Mine, Watched and Reviewing, then Hidden when `showHidden` is on. A pinned
    /// item leaves its own group for Pinned. Each group lists the newest last commit first. A hidden
    /// item shows only in Hidden, even when pinned.
    public static func groups(_ snapshot: Snapshot, pinned: Set<ItemKey>, hidden: Set<ItemKey>, showHidden: Bool) -> [ListGroup] {
        func ordered(_ items: [WatchItem]) -> [WatchItem] {
            items.sorted(by: recentFirst)
        }

        let shown = snapshot.items.filter { !hidden.contains($0.key) }
        let pinnedItems = ordered(shown.filter { pinned.contains($0.key) })
        let unpinned = shown.filter { !pinned.contains($0.key) }

        var groups = pinnedItems.isEmpty ? [] : [ListGroup(title: "Pinned", items: pinnedItems, errors: [:], dimmed: false)]
        groups += [("Mine", Role.authored), ("Watched", .watched), ("Reviewing", .reviewing)].compactMap { title, role -> ListGroup? in
            let items = ordered(unpinned.filter { $0.role == role })
            let errors = role == .watched ? snapshot.watchErrors : [:]
            return items.isEmpty && errors.isEmpty ? nil : ListGroup(title: title, items: items, errors: errors, dimmed: false)
        }

        let hiddenItems = snapshot.items.filter { hidden.contains($0.key) }
        if showHidden && !hiddenItems.isEmpty {
            groups.append(ListGroup(title: "Hidden", items: ordered(hiddenItems), errors: [:], dimmed: true))
        }
        return groups
    }

    /// Hidden items send no notifications. The poller still reads them, so an item that you
    /// unhide shows its current state at once and does not send an old event.
    public static func visibleEvents(_ events: [PipelineEvent], hidden: Set<ItemKey>) -> [PipelineEvent] {
        events.filter { !hidden.contains($0.item.key) }
    }
}
