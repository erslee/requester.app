import Foundation
import Testing
@testable import requester

/// The merge rule, tested directly: "the spec owns the shape, you own
/// everything else." These are the tests that say what pressing Update does to
/// work already done.
struct SpecSyncTests {
    // MARK: - Fixtures

    private func operation(
        key: String = "operationId:createPet",
        method: HTTPMethod = .post,
        url: String = "{{baseUrl}}/pets",
        name: String = "Pets / Create a pet",
        params: [KeyValueItem] = [],
        headers: [KeyValueItem] = [],
        body: String = ""
    ) -> OpenAPISpec.Operation {
        var request = APIRequest(id: "", projectID: "")
        request.method = method
        request.url = url
        request.name = name
        request.params = params
        request.headers = headers
        if !body.isEmpty {
            request.bodyMode = .raw
            request.rawBodyType = .json
            request.rawBody = body
        }
        return OpenAPISpec.Operation(key: key, request: request, generatedBody: body)
    }

    /// A request as it would exist after a first import of `operation()`.
    private func imported(
        _ operation: OpenAPISpec.Operation, id: String = "r1"
    ) -> APIRequest {
        var request = operation.request
        request.id = id
        request.projectID = "p1"
        request.spec = SpecLink(key: operation.key, generatedBody: operation.generatedBody)
        return request
    }

    // MARK: - Adding

    @Test func anOperationWithNoMatchIsAdded() {
        // Act
        let plan = SpecSync.plan(existing: [], incoming: [operation()])

        // Assert
        #expect(plan.added.count == 1)
        #expect(plan.updated.isEmpty)
        #expect(plan.removed.isEmpty)
    }

    @Test func anUnchangedOperationProducesNoWrites() {
        // Arrange
        let spec = operation()
        let existing = imported(spec)

        // Act
        let plan = SpecSync.plan(existing: [existing], incoming: [spec])

        // Assert
        #expect(plan.isEmpty)
        #expect(plan.unchangedCount == 1)
    }

    // MARK: - The merge rule

    @Test func theSpecOwnsMethodAndURL() {
        // Arrange
        let existing = imported(operation())
        let changed = operation(method: .put, url: "{{baseUrl}}/pets/{{petId}}")

        // Act
        let plan = SpecSync.plan(existing: [existing], incoming: [changed])

        // Assert
        #expect(plan.updated.first?.method == .put)
        #expect(plan.updated.first?.url == "{{baseUrl}}/pets/{{petId}}")
    }

    /// The heart of it: a refresh must not cost the user their token script,
    /// their credentials, or the name they gave the request.
    @Test func youOwnTheNameAuthAndScript() throws {
        // Arrange -- an imported request the user has since made their own
        var existing = imported(operation())
        existing.name = "Create a pet (staging)"
        existing.auth.type = .bearer
        existing.auth.bearerToken = "{{token}}"
        existing.postResponseScript = "variables.petId = response.json().id"
        existing.scriptTimeoutSeconds = 12

        // Act
        let plan = SpecSync.plan(
            existing: [existing], incoming: [operation(method: .put, name: "Pets / Add a pet")]
        )

        // Assert
        let updated = try #require(plan.updated.first)
        #expect(updated.method == .put, "the spec still owns the shape")
        #expect(updated.name == "Create a pet (staging)")
        #expect(updated.auth.type == .bearer)
        #expect(updated.auth.bearerToken == "{{token}}")
        #expect(updated.postResponseScript == "variables.petId = response.json().id")
        #expect(updated.scriptTimeoutSeconds == 12)
    }

    @Test func anUntouchedBodyIsRegeneratedFromTheNewSchema() {
        // Arrange -- the body is still exactly what the last sync generated
        let first = operation(body: #"{"name" : "string"}"#)
        let existing = imported(first)

        // Act
        let plan = SpecSync.plan(
            existing: [existing],
            incoming: [operation(body: #"{"name" : "string", "tag" : "string"}"#)]
        )

        // Assert
        #expect(plan.updated.first?.rawBody == #"{"name" : "string", "tag" : "string"}"#)
        #expect(plan.updated.first?.spec?.generatedBody == #"{"name" : "string", "tag" : "string"}"#)
    }

    /// The moment you edit a body it is yours, and no later refresh takes it back.
    @Test func anEditedBodyIsNeverOverwritten() {
        // Arrange
        var existing = imported(operation(body: #"{"name" : "string"}"#))
        existing.rawBody = #"{"name" : "Ada", "tag" : "cat"}"#

        // Act
        let merged = SpecSync.merged(
            operation(body: #"{"name" : "string", "breed" : "string"}"#), into: existing
        )

        // Assert
        #expect(merged.rawBody == #"{"name" : "Ada", "tag" : "cat"}"#)
        // And the remembered example must not move to the one that was never
        // applied, or the next sync would mistake this body for untouched.
        #expect(merged.spec?.generatedBody == #"{"name" : "string"}"#)
    }

    /// Repeated refreshes must keep converging on the same answer rather than
    /// drifting -- the second Update has to be as safe as the first.
    @Test func anEditedBodyStaysUntouchedAcrossRepeatedSyncs() {
        // Arrange
        var existing = imported(operation(body: #"{"name" : "string"}"#))
        existing.rawBody = #"{"name" : "Ada"}"#
        let incoming = operation(body: #"{"changed" : "string"}"#)

        // Act -- merge twice, as a user hitting Update again would
        let once = SpecSync.merged(incoming, into: existing)
        let twice = SpecSync.merged(incoming, into: once)

        // Assert
        #expect(once.rawBody == #"{"name" : "Ada"}"#)
        #expect(twice == once)
    }

    /// A body the user owns is not a reason to rewrite the file. If the only
    /// difference between the document and the request is one the merge rule
    /// refuses to apply, the sync has nothing to do.
    @Test func aBodyOnlyDifferenceIsNotAPointlessWrite() {
        // Arrange
        var existing = imported(operation(body: #"{"name" : "string"}"#))
        existing.rawBody = #"{"name" : "Ada"}"#

        // Act
        let plan = SpecSync.plan(
            existing: [existing], incoming: [operation(body: #"{"changed" : "string"}"#)]
        )

        // Assert
        #expect(plan.isEmpty)
        #expect(plan.unchangedCount == 1)
    }

    @Test func aParameterKeepsItsValueAndToggleButNotItsExistence() throws {
        // Arrange -- the user filled in `limit` and switched it on
        var existing = imported(
            operation(params: [
                KeyValueItem(key: "limit", value: "20", enabled: false),
                KeyValueItem(key: "cursor", value: "", enabled: false),
            ])
        )
        existing.params[0].value = "100"
        existing.params[0].enabled = true

        // Act -- the spec drops `cursor` and adds `status`
        let plan = SpecSync.plan(
            existing: [existing],
            incoming: [
                operation(params: [
                    KeyValueItem(key: "limit", value: "20", enabled: false),
                    KeyValueItem(key: "status", value: "available", enabled: true),
                ])
            ]
        )

        // Assert
        let updated = try #require(plan.updated.first)
        #expect(updated.params.map(\.key) == ["limit", "status"])
        #expect(updated.params[0].value == "100", "the value the user typed survives")
        #expect(updated.params[0].enabled == true)
        #expect(updated.params[1].value == "available", "a new row arrives as the spec describes it")
    }

    // MARK: - Removal and restoration

    @Test func anOperationGoneFromTheSpecIsTombstonedNotDeleted() {
        // Arrange
        let existing = imported(operation())
        let when = Date(timeIntervalSince1970: 1_800_000_000)

        // Act
        let plan = SpecSync.plan(existing: [existing], incoming: [], now: when)

        // Assert -- the request is still here, in full
        #expect(plan.removed.count == 1)
        #expect(plan.removed.first?.id == "r1")
        #expect(plan.removed.first?.spec?.removedAt == when)
        #expect(plan.removed.first?.url == existing.url)
    }

    /// The date has to keep saying when the endpoint actually disappeared, not
    /// when it was last noticed to be missing.
    @Test func anAlreadyTombstonedRequestIsNotRewritten() {
        // Arrange
        var existing = imported(operation())
        existing.spec?.removedAt = Date(timeIntervalSince1970: 1_700_000_000)

        // Act
        let plan = SpecSync.plan(
            existing: [existing], incoming: [], now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        // Assert
        #expect(plan.isEmpty)
    }

    @Test func anOperationThatComesBackIsRestoredInPlace() throws {
        // Arrange -- tombstoned, and carrying history-worthy user work
        var existing = imported(operation())
        existing.spec?.removedAt = Date(timeIntervalSince1970: 1_700_000_000)
        existing.postResponseScript = "variables.id = response.json().id"

        // Act
        let plan = SpecSync.plan(existing: [existing], incoming: [operation()])

        // Assert -- the same request, un-tombstoned; not a duplicate
        #expect(plan.added.isEmpty, "a returning operation must not create a second request")
        #expect(plan.restored.count == 1)
        #expect(plan.restored.first?.id == "r1")
        #expect(plan.restored.first?.spec?.isRemoved == false)
        #expect(plan.restored.first?.postResponseScript == "variables.id = response.json().id")
    }

    // MARK: - Hand-made requests

    /// Nothing in this app deletes or rewrites a request the user wrote
    /// themselves, and a spec sync is no exception.
    @Test func aRequestWithNoSpecLinkIsLeftEntirelyAlone() {
        // Arrange
        var handMade = APIRequest(id: "r9", projectID: "p1")
        handMade.url = "https://api.acme.dev/ping"

        // Act
        let plan = SpecSync.plan(existing: [handMade], incoming: [operation()])

        // Assert
        #expect(plan.removed.isEmpty, "it was never in the document, so it cannot have left it")
        #expect(plan.updated.isEmpty)
        #expect(plan.added.count == 1)
    }

    @Test func aDuplicateKeyMatchesOnlyOnce() throws {
        // Arrange -- only reachable by hand-editing files, but it must not
        // silently overwrite both
        let spec = operation()
        let first = imported(spec, id: "r1")
        let second = imported(spec, id: "r2")

        // Act
        let plan = SpecSync.plan(
            existing: [first, second], incoming: [operation(method: .put)]
        )

        // Assert
        #expect(plan.updated.count == 1)
        #expect(plan.updated.first?.id == "r1")
        #expect(plan.removed.isEmpty)
    }
}
