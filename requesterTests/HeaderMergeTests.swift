import Testing
@testable import requester

/// The merge rule decides which headers reach the server, so the override
/// cases matter as much as the inheriting one.
struct HeaderMergeTests {
    private let global = [
        KeyValueItem(key: "Accept", value: "application/json"),
        KeyValueItem(key: "X-Api-Key", value: "{{key}}"),
        KeyValueItem(key: "X-Off", value: "never", enabled: false),
    ]

    @Test func inheritsEnabledHeadersTheRequestDoesNotName() {
        // Arrange
        var request = APIRequest(id: "r1", projectID: "p1")
        request.headers = [KeyValueItem(key: "X-Trace", value: "1")]

        // Act
        let merged = HeaderMerge.apply(global, to: request)

        // Assert -- a disabled project row is not sent, and the request's own
        // headers come last
        #expect(merged.headers.map(\.key) == ["Accept", "X-Api-Key", "X-Trace"])
        // The template is untouched: variables resolve later, at send time.
        #expect(merged.headers[1].value == "{{key}}")
    }

    @Test func theRequestWinsOnTheSameNameWhateverItsCasing() {
        // Arrange
        var request = APIRequest(id: "r1", projectID: "p1")
        request.headers = [KeyValueItem(key: "accept", value: "text/csv")]

        // Act
        let merged = HeaderMerge.apply(global, to: request)

        // Assert
        #expect(merged.headers.map(\.key) == ["X-Api-Key", "accept"])
        #expect(merged.headers.last?.value == "text/csv")
    }

    /// Switching a row off is the only way to send a request without an
    /// inherited header, so it has to suppress the project's value too.
    @Test func aDisabledRequestRowOptsOutOfTheInheritedHeader() {
        // Arrange
        var request = APIRequest(id: "r1", projectID: "p1")
        request.headers = [KeyValueItem(key: "Accept", value: "", enabled: false)]

        // Act
        let merged = HeaderMerge.apply(global, to: request)

        // Assert -- inherited Accept is gone, and the disabled row itself is
        // dropped by the executor rather than here
        #expect(merged.headers.map(\.key) == ["X-Api-Key", "Accept"])
        #expect(merged.headers.last?.enabled == false)
    }

    @Test func blankRowsOnEitherSideAreIgnored() {
        // Arrange -- the editor keeps a trailing blank row in both tables
        var request = APIRequest(id: "r1", projectID: "p1")
        request.headers = [KeyValueItem()]

        // Act
        let merged = HeaderMerge.apply(global + [KeyValueItem()], to: request)

        // Assert -- the blank request row matches nothing, and no blank is
        // inherited
        #expect(merged.headers.map(\.key) == ["Accept", "X-Api-Key", ""])
    }

    @Test func aProjectWithNoGlobalHeadersLeavesTheRequestAlone() {
        // Arrange
        var request = APIRequest(id: "r1", projectID: "p1")
        request.headers = [KeyValueItem(key: "X-Trace", value: "1")]

        // Act / Assert
        #expect(HeaderMerge.apply([], to: request) == request)
    }
}
