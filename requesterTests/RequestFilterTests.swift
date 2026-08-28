import Testing
@testable import requester

/// What the filter matches decides which rows the sidebar shows at all, so the
/// fields it looks at -- and the empty term that must not hide everything --
/// are what matter.
struct RequestFilterTests {
    private func request(name: String = "", url: String = "", method: HTTPMethod = .get)
        -> APIRequest {
        var request = APIRequest(id: "r1", projectID: "p1", name: name)
        request.url = url
        request.method = method
        return request
    }

    @Test func matchesTheNameTheURLOrTheMethod() {
        // Arrange
        let target = request(name: "Create user", url: "https://api.example.com/users", method: .post)

        // Act / Assert -- each field on its own finds it
        #expect(RequestFilter.matches(target, displayName: "Create user", query: "user"))
        #expect(RequestFilter.matches(target, displayName: "Create user", query: "example.com"))
        #expect(RequestFilter.matches(target, displayName: "Create user", query: "POST"))
        #expect(!RequestFilter.matches(target, displayName: "Create user", query: "delete"))
    }

    @Test func ignoresCase() {
        // Arrange
        let target = request(name: "Create User", url: "https://api.example.com/Users")

        // Act / Assert
        #expect(RequestFilter.matches(target, displayName: "Create User", query: "cReAtE"))
        #expect(RequestFilter.matches(target, displayName: "Create User", query: "USERS"))
    }

    /// The row is labelled from its URL when it has no name, so that is the
    /// text a search has to find -- not the empty `name` field behind it.
    @Test func matchesTheDerivedLabelOfAnUnnamedRequest() {
        // Arrange
        let target = request(url: "https://swapi.info/planets")
        let label = RequestNaming.displayName(for: target)

        // Act / Assert
        #expect(label == "swapi.info/planets")
        #expect(RequestFilter.matches(target, displayName: label, query: "planets"))
    }

    /// An empty field is not a filter. `normalized` returning nil is what the
    /// sidebar reads to leave the list alone -- `matches` is never consulted.
    @Test func anEmptyOrBlankTermMatchesNothing() {
        // Arrange
        let target = request(name: "Create user", url: "https://api.example.com/users")

        // Act / Assert
        #expect(!RequestFilter.matches(target, displayName: "Create user", query: ""))
        #expect(!RequestFilter.matches(target, displayName: "Create user", query: "   "))
        #expect(RequestFilter.normalized("  users  ") == "users")
        #expect(RequestFilter.normalized("   ") == nil)
    }

    /// Whitespace around a term is typing noise, not part of what was meant.
    @Test func trimsTheTermBeforeMatching() {
        // Arrange
        let target = request(name: "Create user", url: "https://api.example.com/users")

        // Act / Assert
        #expect(RequestFilter.matches(target, displayName: "Create user", query: "  user  "))
    }
}
