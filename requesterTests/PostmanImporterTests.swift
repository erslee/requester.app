import Foundation
import Testing
@testable import requester

/// The importer walks loose dictionaries because Postman's schema varies in
/// shape, so each variation it has to survive is pinned here.
struct PostmanImporterTests {
    private func collection(_ json: String) throws -> PostmanImporter.Collection {
        try PostmanImporter.collection(from: Data(json.utf8))
    }

    private func wrap(_ items: String, variables: String = "[]", events: String = "[]") -> String {
        """
        {"info":{"name":"Imagery","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
         "variable":\(variables),"event":\(events),"item":[\(items)]}
        """
    }

    @Test func readsTheCollectionNameVariablesAndRequests() throws {
        // Arrange / Act
        let imported = try collection(
            wrap(
                #"{"name":"list","request":{"method":"GET","url":"https://x.com/a"}}"#,
                variables: #"[{"key":"token","value":"abc"},{"key":"host","value":""}]"#
            )
        )

        // Assert
        #expect(imported.name == "Imagery")
        #expect(imported.variables == ["token": "abc", "host": ""])
        #expect(imported.requests.count == 1)
        #expect(imported.requests[0].name == "list")
        #expect(imported.requests[0].method == .get)
        #expect(imported.requests[0].url == "https://x.com/a")

        // Assert -- ids are left for the caller, order preserved
        #expect(imported.requests[0].id.isEmpty)
        #expect(imported.requests[0].projectID.isEmpty)
        #expect(imported.requests[0].order == 0)
    }

    /// Folders have no equivalent, so their names are kept in the request name
    /// rather than thrown away.
    @Test func flattensFoldersIntoRequestNames() throws {
        // Arrange / Act
        let imported = try collection(
            wrap(#"""
            {"name":"Kraken","item":[
              {"name":"Outer","request":{"method":"GET","url":"https://x.com/1"}},
              {"name":"Inner","item":[{"name":"Deep","request":{"method":"GET","url":"https://x.com/2"}}]}
            ]}
            """#)
        )

        // Assert
        #expect(imported.requests.map(\.name) == ["Kraken / Outer", "Kraken / Inner / Deep"])
        #expect(imported.requests.map(\.order) == [0, 1])
    }

    @Test func assemblesAURLFromItsPartsWhenRawIsAbsent() throws {
        // Arrange / Act
        let imported = try collection(wrap(#"""
        {"name":"local","request":{"method":"GET","url":{
          "protocol":"http","host":["localhost"],"port":"3664","path":["api","overlays"]}}}
        """#))

        // Assert
        #expect(imported.requests[0].url == "http://localhost:3664/api/overlays")
    }

    /// Query values arrive percent-encoded; the sender encodes again, so leaving
    /// them encoded would send `%7B` as `%257B`.
    @Test func decodesQueryValuesSoTheyAreNotEncodedTwice() throws {
        // Arrange / Act
        let imported = try collection(wrap(#"""
        {"name":"q","request":{"method":"GET","url":{
          "raw":"https://x.com/a?context=%7B%22id%22%3A%221%22%7D&n=2",
          "host":["x","com"],"path":["a"],
          "query":[{"key":"context","value":"%7B%22id%22%3A%221%22%7D"},
                   {"key":"n","value":"2"},
                   {"key":"off","value":"3","disabled":true}]}}}
        """#))

        // Assert -- decoded, and the query is out of the URL
        let request = imported.requests[0]
        #expect(request.url == "https://x.com/a")
        #expect(request.params.map(\.key) == ["context", "n", "off"])
        #expect(request.params[0].value == #"{"id":"1"}"#)
        #expect(request.params[2].enabled == false)
    }

    /// Path variables have no equivalent, so their values are substituted the
    /// way Postman would have sent them.
    @Test func substitutesPathVariables() throws {
        // Arrange / Act
        let imported = try collection(wrap(#"""
        {"name":"tile","request":{"method":"GET","url":{
          "raw":"https://x.com/grid/:mapId/:z/png","host":["x","com"],
          "path":["grid",":mapId",":z","png"],
          "variable":[{"key":"mapId","value":"abc"},{"key":"z","value":"7"},{"key":"empty","value":""}]}}}
        """#))

        // Assert
        #expect(imported.requests[0].url == "https://x.com/grid/abc/7/png")
        #expect(imported.warnings.contains { $0.contains("2 path variables") })
    }

    @Test func readsHeadersIncludingDisabledOnes() throws {
        // Arrange / Act
        let imported = try collection(wrap(#"""
        {"name":"h","request":{"method":"GET","url":"https://x.com",
          "header":[{"key":"accept","value":"application/json"},
                    {"key":"x-off","value":"1","disabled":true},
                    {"key":"","value":"ignored"}]}}
        """#))

        // Assert -- the nameless one is dropped, the disabled one is kept but off
        let headers = imported.requests[0].headers
        #expect(headers.map(\.key) == ["accept", "x-off"])
        #expect(headers[0].enabled)
        #expect(headers[1].enabled == false)
    }

    @Test func mapsEachAuthSchemeItSupports() throws {
        // Arrange / Act
        let imported = try collection(wrap(#"""
        {"name":"bearer","request":{"method":"GET","url":"https://x.com","auth":{"type":"bearer",
          "bearer":[{"key":"token","value":"{{tok}}"}]}}},
        {"name":"basic","request":{"method":"GET","url":"https://x.com","auth":{"type":"basic",
          "basic":[{"key":"username","value":"ada"},{"key":"password","value":"lovelace"}]}}},
        {"name":"apikey","request":{"method":"GET","url":"https://x.com","auth":{"type":"apikey",
          "apikey":[{"key":"key","value":"X-Key"},{"key":"value","value":"secret"},{"key":"in","value":"query"}]}}},
        {"name":"oauth","request":{"method":"GET","url":"https://x.com","auth":{"type":"oauth2"}}}
        """#))

        // Assert
        #expect(imported.requests[0].auth.type == .bearer)
        #expect(imported.requests[0].auth.bearerToken == "{{tok}}")
        #expect(imported.requests[1].auth.basicUsername == "ada")
        #expect(imported.requests[1].auth.basicPassword == "lovelace")
        #expect(imported.requests[2].auth.apiKeyName == "X-Key")
        #expect(imported.requests[2].auth.apiKeyIn == .query)

        // Assert -- an unsupported scheme is reported, not silently dropped
        #expect(imported.requests[3].auth.type == .none)
        #expect(imported.warnings.contains { $0.contains("oauth2") })
    }

    @Test func mapsBodyModes() throws {
        // Arrange / Act
        let imported = try collection(wrap(#"""
        {"name":"raw","request":{"method":"POST","url":"https://x.com","body":{"mode":"raw",
          "raw":"{\"a\":1}","options":{"raw":{"language":"json"}}}}},
        {"name":"gql","request":{"method":"POST","url":"https://x.com","body":{"mode":"graphql",
          "graphql":{"query":"query Me { me }","variables":"{\"id\":1}"}}}},
        {"name":"form","request":{"method":"POST","url":"https://x.com","body":{"mode":"urlencoded",
          "urlencoded":[{"key":"a","value":"1"},{"key":"b","value":"2","disabled":true}]}}},
        {"name":"file","request":{"method":"POST","url":"https://x.com","body":{"mode":"file",
          "file":{"src":"/tmp/x"}}}}
        """#))

        // Assert -- raw JSON
        #expect(imported.requests[0].bodyMode == .raw)
        #expect(imported.requests[0].rawBodyType == .json)
        #expect(imported.requests[0].rawBody == #"{"a":1}"#)

        // Assert -- GraphQL, with its variables reformatted
        #expect(imported.requests[1].bodyMode == .graphQL)
        #expect(imported.requests[1].graphQLBody?.query == "query Me { me }")
        #expect(imported.requests[1].graphQLBody?.variablesJSON.contains("\"id\"") == true)

        // Assert -- form fields, disabled state kept
        #expect(imported.requests[2].bodyMode == .form)
        #expect(imported.requests[2].formFields.map(\.enabled) == [true, false])

        // Assert -- an unsupported mode is reported
        #expect(imported.warnings.contains { $0.contains("file") })
    }

    /// A raw JSON body carrying a `query` is really a GraphQL request.
    @Test func recognisesGraphQLSentAsARawBody() throws {
        // Arrange / Act
        let imported = try collection(wrap(#"""
        {"name":"gql-raw","request":{"method":"POST","url":"https://x.com","body":{"mode":"raw",
          "raw":"{\"operationName\":\"Me\",\"variables\":{\"id\":1},\"query\":\"query Me { me }\"}"}}}
        """#))

        // Assert
        #expect(imported.requests[0].bodyMode == .graphQL)
        #expect(imported.requests[0].graphQLBody?.operationName == "Me")
        #expect(imported.requests[0].rawBody.isEmpty)
    }

    @Test func reportsWhatItCannotBring() throws {
        // Arrange / Act -- collection-level scripts and a pre-request script
        let imported = try collection(
            wrap(
                #"""
                {"name":"r","request":{"method":"GET","url":"https://x.com"},
                 "event":[{"listen":"prerequest","script":{"exec":["console.log(1)"]}}]}
                """#,
                events: #"[{"listen":"prerequest","script":{"exec":["a"]}}]"#
            )
        )

        // Assert
        #expect(imported.warnings.contains { $0.contains("Collection-level") })
        #expect(imported.warnings.contains { $0.contains("r:") && $0.contains("prerequest") })
        #expect(imported.requests[0].postResponseScript.isEmpty)
    }

    @Test func rejectsFilesThatAreNotCollections() {
        #expect(throws: PostmanImportError.self) {
            try PostmanImporter.collection(from: Data("not json".utf8))
        }
        #expect(throws: PostmanImportError.self) {
            try PostmanImporter.collection(from: Data(#"{"hello":"world"}"#.utf8))
        }
        #expect(throws: PostmanImportError.self) {
            try collection(wrap(""))   // a collection with no requests
        }
    }
}

/// Translating Postman's `pm` API is what makes an imported collection's auth
/// chaining actually work.
struct PostmanScriptTests {
    @Test func joinsExecLines() {
        #expect(PostmanScript.source(from: ["a", "b", ""]) == "a\nb\n")
        #expect(PostmanScript.source(from: "single") == "single")
        #expect(PostmanScript.source(from: nil).isEmpty)
    }

    @Test func translatesReadingTheResponseAndWritingVariables() {
        // Arrange -- the real script from the sample collection
        let source = """
            const jsonData = pm.response.json();
            pm.collectionVariables.set("spaceKnow_token", jsonData.id_token);
            """

        // Act
        let translated = PostmanScript.translated(source)

        // Assert
        #expect(translated == """
            const jsonData = response.json();
            variables["spaceKnow_token"] = jsonData.id_token;
            """)
        #expect(!PostmanScript.stillReferencesPostman(translated))
    }

    @Test func translatesEveryVariableScopeAndTheResponseAccessors() {
        #expect(PostmanScript.translated(#"pm.environment.set('a', 1)"#) == #"variables["a"] = 1"#)
        #expect(PostmanScript.translated(#"pm.globals.set("a", x)"#) == #"variables["a"] = x"#)
        #expect(PostmanScript.translated(#"pm.variables.get("a")"#) == #"variables["a"]"#)
        #expect(PostmanScript.translated("pm.response.code") == "response.statusCode")
        #expect(PostmanScript.translated("pm.response.text()") == "response.text")
        #expect(
            PostmanScript.translated(#"pm.response.headers.get("etag")"#)
                == #"response.headers["etag"]"#
        )
    }

    @Test func flagsCallsItCannotTranslate() {
        // Arrange -- assertions have no equivalent in our runner
        let source = #"pm.test("ok", function () { pm.expect(pm.response.code).to.eql(200); });"#

        // Act
        let translated = PostmanScript.translated(source)

        // Assert -- the response accessor is rewritten, the rest is left and flagged
        #expect(translated.contains("response.statusCode"))
        #expect(PostmanScript.stillReferencesPostman(translated))
    }
}
