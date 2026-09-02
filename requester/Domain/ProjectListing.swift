import Foundation

/// The order and the filtering behind the launcher's project list.
///
/// Pure, and taking plain ids rather than `RecentProjectsStore`, so the rule
/// can be tested without `UserDefaults` or the main actor -- and so `Domain/`
/// keeps depending on nothing above it.
nonisolated enum ProjectListing {
    /// Every project, most useful first, narrowed by what was typed.
    ///
    /// Recently opened ones lead, in the order they were opened; everything
    /// else follows alphabetically. One list rather than two sections: the
    /// recents are worth putting at the top, but not worth a heading and a
    /// disclosure triangle between you and the rest of your projects.
    ///
    /// Only a handful of ids are remembered (`RecentProjectsStore.limit`), so
    /// on a folder with more projects than that the tail is always the
    /// alphabetical part -- which is exactly when the filter earns its place.
    static func ordered(
        _ projects: [Project], recentIDs: [String], matching query: String = ""
    ) -> [Project] {
        let byID = Dictionary(
            projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )

        // A remembered id is a hint, never a promise: the data folder can be
        // swapped or edited by hand, so one that no longer resolves is dropped.
        let recent = recentIDs.compactMap { byID[$0] }
        let recentIDSet = Set(recent.map(\.id))
        let rest = projects
            .filter { !recentIDSet.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return filtered(recent + rest, matching: query)
    }

    /// Whether one project survives what was typed. Matching on the name only:
    /// it is the sole thing the row shows, and a list that kept a row whose
    /// visible text does not contain the query reads as broken.
    static func matches(_ project: Project, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return project.name.localizedCaseInsensitiveContains(trimmed)
    }

    /// Where the keyboard selection lands after moving `offset` rows.
    ///
    /// Clamped at both ends rather than wrapping: holding the arrow key down
    /// should come to rest at the last project, not cycle back past the first.
    ///
    /// Also the rule for keeping a selection honest as the list changes under
    /// it. A selection the filter has hidden -- or one whose project is gone --
    /// is not carried forward; the list starts again from its top, which is
    /// what typing another character should do.
    static func selecting(
        from selection: String?, movedBy offset: Int, in projects: [Project]
    ) -> String? {
        guard !projects.isEmpty else { return nil }
        guard let selection, let current = projects.firstIndex(where: { $0.id == selection })
        else { return projects.first?.id }

        let moved = min(max(current + offset, 0), projects.count - 1)
        return projects[moved].id
    }

    private static func filtered(_ projects: [Project], matching query: String) -> [Project] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return projects }
        return projects.filter { matches($0, query: trimmed) }
    }
}
