import Testing
@testable import requester

/// The tree is what the sidebar draws and what moving a folder rewrites, so the
/// shape it produces and the guards against a malformed move are what matter.
struct FolderTreeTests {
    private func request(_ id: String, folder: [String] = [], order: Int = 0) -> APIRequest {
        var request = APIRequest(id: id, projectID: "p1", name: id, order: order)
        request.folder = folder
        return request
    }

    @Test func nestsRequestsUnderTheirFolders() {
        // Arrange
        let requests = [
            request("loose"),
            request("listUsers", folder: ["Users"]),
            request("promote", folder: ["Users", "Admin"]),
            request("listPets", folder: ["Pets"]),
        ]

        // Act
        let root = FolderTree.roots(requests: requests, declared: [])

        // Assert -- folders sorted by name, loose requests at the top level
        #expect(root.children.map(\.name) == ["Pets", "Users"])
        #expect(root.requests.map(\.id) == ["loose"])

        let users = root.children[1]
        #expect(users.requests.map(\.id) == ["listUsers"])
        #expect(users.children.map(\.name) == ["Admin"])
        #expect(users.children[0].requests.map(\.id) == ["promote"])
    }

    /// A request filed two levels deep still has to draw its parent folder,
    /// even though nothing sits directly in it.
    @Test func drawsTheAncestorsAPathImplies() {
        // Arrange / Act
        let root = FolderTree.roots(
            requests: [request("deep", folder: ["A", "B", "C"])], declared: []
        )

        // Assert
        #expect(root.children.map(\.name) == ["A"])
        #expect(root.children[0].children.map(\.name) == ["B"])
        #expect(root.children[0].children[0].children.map(\.name) == ["C"])
        #expect(root.children[0].children[0].children[0].requests.map(\.id) == ["deep"])
    }

    /// A folder made and not yet filled must survive: that is the moment the
    /// user is about to drag something into it.
    @Test func keepsAnEmptyFolderThatWasDeclared() {
        // Arrange / Act
        let root = FolderTree.roots(requests: [], declared: [["Scratch"]])

        // Assert
        #expect(root.children.map(\.name) == ["Scratch"])
        #expect(root.children[0].isEmpty)
    }

    @Test func requestsKeepTheirOwnOrderInsideAFolder() {
        // Arrange
        let requests = [
            request("second", folder: ["Users"], order: 1),
            request("first", folder: ["Users"], order: 0),
        ]

        // Act -- the repository hands them over already sorted
        let root = FolderTree.roots(
            requests: requests.sorted { $0.order < $1.order }, declared: []
        )

        // Assert -- folder contents are not re-sorted by name
        #expect(root.children[0].requests.map(\.id) == ["first", "second"])
    }

    /// Two folders may share a name at different places in the tree, so the
    /// identifier has to be the whole path.
    @Test func identifiesFoldersByTheirFullPath() {
        // Arrange / Act / Assert
        #expect(
            FolderTree.identifier(for: ["Users", "Admin"])
                != FolderTree.identifier(for: ["Pets", "Admin"])
        )
        // A name may contain the character a naive join would use.
        #expect(
            FolderTree.identifier(for: ["GET / POST"])
                != FolderTree.identifier(for: ["GET", "POST"])
        )
    }

    @Test func namesANewFolderAroundWhatIsAlreadyThere() {
        // Arrange
        let paths: Set<[String]> = [["New Folder"], ["New Folder 2"]]

        // Act / Assert
        #expect(FolderTree.availableName("New Folder", in: [], among: paths) == "New Folder 3")
        #expect(FolderTree.availableName("New Folder", in: ["Users"], among: paths) == "New Folder")
    }

    /// Dragging a folder into its own descendant would detach the branch from
    /// the tree entirely.
    @Test func refusesToTreatAFolderAsMovableIntoItself() {
        // Act / Assert
        #expect(FolderTree.isSelfOrDescendant(["A", "B"], of: ["A"]))
        #expect(FolderTree.isSelfOrDescendant(["A"], of: ["A"]))
        #expect(!FolderTree.isSelfOrDescendant(["A"], of: ["A", "B"]))
        #expect(!FolderTree.isSelfOrDescendant(["B"], of: ["A"]))
    }

    @Test func rewritesPathsUnderAMovedOrRenamedFolder() {
        // Act / Assert -- a rename is a rewrite in place
        #expect(
            FolderTree.rewriting(["Users", "Admin"], from: ["Users"], to: ["People"])
                == ["People", "Admin"]
        )
        // A move re-parents the whole branch
        #expect(
            FolderTree.rewriting(["Users", "Admin"], from: ["Users"], to: ["Pets", "Users"])
                == ["Pets", "Users", "Admin"]
        )
        // Untouched paths report as such rather than being rewritten to nothing
        #expect(FolderTree.rewriting(["Pets"], from: ["Users"], to: ["People"]) == nil)
    }

    /// The sidebar draws one flat sequence of rows, so the walk that produces
    /// it -- order, depth, and what a collapsed folder hides -- is the part
    /// worth pinning down.
    @Test func flattensTheTreeInDrawingOrder() {
        // Arrange
        let requests = [
            request("loose"),
            request("listUsers", folder: ["Users"]),
            request("promote", folder: ["Users", "Admin"]),
        ]
        let root = FolderTree.roots(requests: requests, declared: [])

        // Act -- everything open
        let rows = FolderTree.flattened(root) { _ in true }

        // Assert -- folder, its contents, then the level's own requests last
        #expect(rows.map(\.id) == ["f:Users", "f:Users\u{1F}Admin", "r:promote", "r:listUsers", "r:loose"])

        // Assert -- a request carries the depth its indentation needs
        if case .request(_, let depth) = rows[2] { #expect(depth == 2) } else { Issue.record("not a request") }
        if case .request(_, let depth) = rows[4] { #expect(depth == 0) } else { Issue.record("not a request") }
    }

    @Test func aCollapsedFolderHidesEverythingUnderIt() {
        // Arrange
        let root = FolderTree.roots(
            requests: [
                request("listUsers", folder: ["Users"]),
                request("promote", folder: ["Users", "Admin"]),
                request("loose"),
            ],
            declared: []
        )

        // Act -- "Users" closed
        let rows = FolderTree.flattened(root) { $0 != ["Users"] }

        // Assert -- the folder is still a row; its subtree is not
        #expect(rows.map(\.id) == ["f:Users", "r:loose"])
    }
}
