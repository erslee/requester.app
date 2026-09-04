import Foundation
import Testing
@testable import requester

/// A response on screen belongs to the request it came from, so moving the
/// sidebar off that request and back must bring it -- and its history row --
/// back with it, rather than leaving an empty panel.
@MainActor
struct ResponseRestoreTests {
    /// The selection change does its work in a task of its own, so a test that
    /// looks straight after setting `selection` would read the state it is
    /// about to replace.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<20 { await Task.yield() }
    }

    /// A project with two requests, in a model that has finished loading.
    private func loadedModel() async throws -> (AppModel, APIRequest, APIRequest) {
        let storage = InMemoryStorage()
        let project = try await ProjectRepository(storage: storage).create(name: "Petstore")
        let requests = RequestRepository(storage: storage)
        let alpha = try await requests.create(projectID: project.id, name: "alpha")
        let beta = try await requests.create(projectID: project.id, name: "beta")

        let model = AppModel(
            storage: storage,
            projectID: project.id,
            interfaceState: InterfaceStateStore(
                projectID: project.id,
                defaults: UserDefaults(suiteName: "requester-tests-\(UUID().uuidString)")!
            )
        )
        await model.load()
        await settle()
        return (model, alpha, beta)
    }

    private func entry(for request: APIRequest, status: Int = 200) -> HistoryEntry {
        var entry = HistoryEntry(
            id: "entry-\(request.id)",
            projectID: request.projectID,
            requestID: request.id,
            requestSnapshot: request,
            resolvedURL: "https://example.com/\(request.name)",
            sentAt: Date()
        )
        var response = ResponseRecord(statusCode: status)
        response.bodyText = #"{"ok": true}"#
        entry.response = response
        return entry
    }

    @Test func loadingARequestBringsBackTheResponseItLastShowed() async throws {
        // Arrange -- alpha open, with a response on screen
        let (model, alpha, beta) = try await loadedModel()
        let editor = model.editor
        editor.load(alpha)
        editor.lastEntry = entry(for: alpha)

        // Act -- away to beta, which has none of its own, and back
        editor.load(beta)
        #expect(editor.lastEntry == nil)
        editor.load(alpha)

        // Assert
        #expect(editor.lastEntry?.id == "entry-\(alpha.id)")
        #expect(editor.lastEntry?.response?.statusCode == 200)
    }

    /// Only the newest is worth keeping: a second send replaces what the panel
    /// is showing, so that is what coming back has to find.
    @Test func onlyTheLatestResponseIsRemembered() async throws {
        // Arrange
        let (model, alpha, beta) = try await loadedModel()
        let editor = model.editor
        editor.load(alpha)
        editor.lastEntry = entry(for: alpha, status: 500)

        var resent = entry(for: alpha)
        resent.id = "entry-resent"
        editor.lastEntry = resent

        // Act
        editor.load(beta)
        editor.load(alpha)

        // Assert
        #expect(editor.lastEntry?.id == "entry-resent")
        #expect(editor.lastEntry?.response?.statusCode == 200)
    }

    /// Closing the editor entirely -- a project or folder row -- clears the
    /// panel, but must not forget what the request had.
    @Test func clearingTheEditorDoesNotForgetTheResponse() async throws {
        // Arrange
        let (model, alpha, _) = try await loadedModel()
        let editor = model.editor
        editor.load(alpha)
        editor.lastEntry = entry(for: alpha)

        // Act
        editor.clear()
        #expect(editor.lastEntry == nil)
        editor.load(alpha)

        // Assert
        #expect(editor.lastEntry?.id == "entry-\(alpha.id)")
    }

    /// The whole point, driven the way the sidebar drives it: the panel and the
    /// active history row both come back.
    @Test func switchingRequestsAndBackKeepsTheResponseAndItsHistoryRow() async throws {
        // Arrange -- alpha selected, showing a past send
        let (model, alpha, beta) = try await loadedModel()
        model.selection = .request(projectID: model.projectID, requestID: alpha.id)
        await settle()

        model.open(historyEntry: entry(for: alpha))
        await settle()
        #expect(model.editor.lastEntry?.id == "entry-\(alpha.id)")
        #expect(model.historyPanel.selectedEntryID == "entry-\(alpha.id)")

        // Act -- click beta, then click alpha again
        model.selection = .request(projectID: model.projectID, requestID: beta.id)
        await settle()
        #expect(model.editor.lastEntry == nil)
        #expect(model.historyPanel.selectedEntryID == nil)

        model.selection = .request(projectID: model.projectID, requestID: alpha.id)
        await settle()

        // Assert
        #expect(model.editor.lastEntry?.id == "entry-\(alpha.id)")
        #expect(model.historyPanel.selectedEntryID == "entry-\(alpha.id)")
    }
}
