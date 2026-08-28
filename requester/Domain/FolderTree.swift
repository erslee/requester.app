import Foundation

/// Turns a project's requests and its hand-made folders into the nested rows
/// the sidebar draws, and owns the path arithmetic that moving and renaming a
/// folder needs.
///
/// A folder is a path, not an entity: it exists because requests are in it, or
/// because the user made it and the project remembers it. That means every
/// operation here is a rewrite of strings rather than a graph edit -- rename a
/// folder and its descendants' paths change with it, which is the price of not
/// carrying ids for something the user only ever sees as a name.
nonisolated enum FolderTree {
    /// One row of the outline: a folder with whatever is nested inside it, then
    /// the requests that sit directly in it.
    struct Node: Sendable, Hashable, Identifiable {
        /// Full path from the project root, so it is unique across the tree --
        /// two different folders can both be called "Admin".
        var path: [String]
        var children: [Node]
        var requests: [APIRequest]

        var id: String { FolderTree.identifier(for: path) }
        var name: String { path.last ?? "" }

        /// Whether anything at all is inside, at any depth. An empty folder is
        /// still shown -- the user made it on purpose -- but the sidebar wants
        /// to know.
        var isEmpty: Bool { requests.isEmpty && children.allSatisfy(\.isEmpty) }
    }

    /// One line of the sidebar's outline, once the tree has been walked.
    ///
    /// A `List` with selection wants a flat sequence of rows, and a recursive
    /// SwiftUI view cannot name its own return type -- so the walk happens here
    /// and the view draws what comes back.
    enum Row: Sendable, Hashable, Identifiable {
        case folder(Node)
        case request(APIRequest, depth: Int)

        var id: String {
            switch self {
            case .folder(let node): "f:\(node.id)"
            case .request(let request, _): "r:\(request.id)"
            }
        }
    }

    /// The visible rows, depth-first: a folder, then what is inside it if it is
    /// open, then the requests sitting directly at this level.
    static func flattened(
        _ node: Node, isExpanded: (_ path: [String]) -> Bool
    ) -> [Row] {
        var rows: [Row] = []
        for child in node.children {
            rows.append(.folder(child))
            if isExpanded(child.path) {
                rows.append(contentsOf: flattened(child, isExpanded: isExpanded))
            }
        }
        rows.append(contentsOf: node.requests.map { .request($0, depth: node.path.count) })
        return rows
    }

    /// A path as one string, for identity and for `UserDefaults` keys.
    ///
    /// Uses a control character no one types, rather than "/" -- a folder is
    /// allowed to be called "GET / POST", and joining on a character that can
    /// appear in a name would make two different folders collide.
    static let separator = "\u{1F}"

    static func identifier(for path: [String]) -> String {
        path.joined(separator: separator)
    }

    /// Every folder in the project: the ones requests are in, the ones made by
    /// hand, and every ancestor implied by either.
    static func allPaths(requests: [APIRequest], declared: [[String]]) -> Set<[String]> {
        var paths: Set<[String]> = []
        for path in requests.map(\.folder) + declared {
            // A path implies its ancestors, so `["A", "B"]` alone still draws A.
            for depth in 1...max(path.count, 1) where depth <= path.count {
                paths.insert(Array(path.prefix(depth)))
            }
        }
        return paths
    }

    /// The folders and requests directly at `path`, ready to render.
    ///
    /// Requests keep the order they already carry; folders sort by name, so the
    /// tree does not reshuffle itself as requests are added.
    static func node(
        at path: [String], requests: [APIRequest], declared: [[String]]
    ) -> Node {
        let paths = allPaths(requests: requests, declared: declared)
        return build(path: path, paths: paths, requests: requests)
    }

    /// The top level: folders first, then the requests in no folder at all.
    static func roots(requests: [APIRequest], declared: [[String]]) -> Node {
        node(at: [], requests: requests, declared: declared)
    }

    private static func build(
        path: [String], paths: Set<[String]>, requests: [APIRequest]
    ) -> Node {
        let childNames = paths
            .filter { $0.count == path.count + 1 && Array($0.dropLast()) == path }
            .map { $0[path.count] }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return Node(
            path: path,
            children: childNames.map {
                build(path: path + [$0], paths: paths, requests: requests)
            },
            requests: requests.filter { $0.folder == path }
        )
    }

    // MARK: - Editing paths

    /// A folder name that is free at `parent`, so making "New Folder" twice
    /// gives two folders rather than silently reusing the first.
    static func availableName(
        _ base: String, in parent: [String], among paths: Set<[String]>
    ) -> String {
        guard paths.contains(parent + [base]) else { return base }
        for suffix in 2... {
            let candidate = "\(base) \(suffix)"
            if !paths.contains(parent + [candidate]) { return candidate }
        }
        return base
    }

    /// Whether `path` is the same folder as `other`, or inside it. What stops a
    /// folder being dragged into its own descendant, which would detach the
    /// whole branch from the tree.
    static func isSelfOrDescendant(_ path: [String], of other: [String]) -> Bool {
        path.count >= other.count && Array(path.prefix(other.count)) == other
    }

    /// `path` with the `from` prefix swapped for `to`, or `nil` when it was not
    /// under `from` at all. The one rule behind both renaming and moving.
    static func rewriting(_ path: [String], from: [String], to: [String]) -> [String]? {
        guard isSelfOrDescendant(path, of: from) else { return nil }
        return to + path.dropFirst(from.count)
    }
}
