import Foundation
import Testing
@testable import requester

struct OpenAPISpecTests {
    private func parse(_ json: String) throws -> OpenAPISpec.Document {
        try OpenAPISpec.document(from: Data(json.utf8))
    }

    /// A small but complete OpenAPI 3 document, reused by most tests here.
    private var petstore: String {
        #"""
        {
          "openapi": "3.0.3",
          "info": { "title": "Petstore" },
          "servers": [{ "url": "https://api.petstore.dev/v1" }],
          "paths": {
            "/pets": {
              "get": {
                "operationId": "listPets",
                "summary": "List pets",
                "tags": ["Pets"],
                "parameters": [
                  { "name": "limit", "in": "query", "schema": { "type": "integer", "default": 20 } },
                  { "name": "status", "in": "query", "required": true,
                    "schema": { "type": "string", "enum": ["available", "sold"] } },
                  { "name": "X-Trace", "in": "header", "schema": { "type": "string" } }
                ]
              },
              "post": {
                "operationId": "createPet",
                "summary": "Create a pet",
                "tags": ["Pets"],
                "requestBody": {
                  "content": {
                    "application/json": {
                      "schema": {
                        "type": "object",
                        "properties": {
                          "name": { "type": "string" },
                          "tag": { "type": "string" }
                        }
                      }
                    }
                  }
                }
              }
            },
            "/pets/{petId}": {
              "parameters": [
                { "name": "petId", "in": "path", "required": true, "schema": { "type": "string" } }
              ],
              "delete": { "operationId": "deletePet", "summary": "Delete a pet", "tags": ["Pets"] }
            }
          }
        }
        """#
    }

    // MARK: - Shape

    @Test func readsTitleServerAndEveryOperation() throws {
        // Act
        let document = try parse(petstore)

        // Assert
        #expect(document.title == "Petstore")
        #expect(document.serverURL == "https://api.petstore.dev/v1")
        #expect(document.operations.count == 3)
        #expect(document.operations.map(\.request.method) == [.get, .post, .delete])
    }

    /// The server URL belongs in a variable, not baked into every request --
    /// one edit then repoints the whole project at staging.
    @Test func urlsStartFromTheBaseURLVariable() throws {
        let document = try parse(petstore)
        let urls = document.operations.map(\.request.url)

        #expect(urls.contains("{{baseUrl}}/pets"))
        #expect(urls.contains("{{baseUrl}}/pets/{{petId}}"))
    }

    @Test func rewritesPathTemplatesIntoAppVariables() {
        #expect(
            OpenAPISpec.rewritingPathTemplates(in: "/orders/{orderId}/items/{itemId}")
                == "/orders/{{orderId}}/items/{{itemId}}"
        )
    }

    @Test func namesAnOperationByTagAndSummary() throws {
        let document = try parse(petstore)
        #expect(document.operations.map(\.request.name).contains("Pets / List pets"))
    }

    /// Identity has to survive a rename, so operationId is preferred over the path.
    @Test func prefersOperationIdForIdentity() throws {
        let document = try parse(petstore)
        #expect(document.operations.map(\.key).contains("operationId:listPets"))
    }

    @Test func fallsBackToMethodAndPathWithoutAnOperationId() throws {
        let document = try parse(#"""
            {
              "openapi": "3.0.0",
              "info": { "title": "X" },
              "paths": { "/health": { "get": { "summary": "Health" } } }
            }
            """#)

        #expect(document.operations.map(\.key) == ["GET /health"])
    }

    // MARK: - Parameters

    @Test func splitsParametersByLocationAndSeedsTheirValues() throws {
        // Act
        let document = try parse(petstore)
        let list = try #require(document.operations.first { $0.key == "operationId:listPets" })

        // Assert -- query params keep their example/default/enum value
        #expect(list.request.params.map(\.key) == ["limit", "status"])
        #expect(list.request.params.map(\.value) == ["20", "available"])
        #expect(list.request.headers.map(\.key) == ["X-Trace"])
    }

    /// A fresh import should send the minimum the endpoint accepts, so anything
    /// the spec does not require starts switched off.
    @Test func onlyRequiredParametersStartEnabled() throws {
        let document = try parse(petstore)
        let list = try #require(document.operations.first { $0.key == "operationId:listPets" })

        #expect(list.request.params.first { $0.key == "status" }?.enabled == true)
        #expect(list.request.params.first { $0.key == "limit" }?.enabled == false)
    }

    /// Path-level parameters apply to every operation underneath them, and a
    /// path parameter is already in the URL rather than being a query param.
    @Test func pathLevelParametersDoNotBecomeQueryParameters() throws {
        let document = try parse(petstore)
        let delete = try #require(document.operations.first { $0.key == "operationId:deletePet" })

        #expect(delete.request.params.isEmpty)
        #expect(delete.request.url == "{{baseUrl}}/pets/{{petId}}")
    }

    // MARK: - Bodies

    @Test func generatesAJSONBodyAndRemembersIt() throws {
        // Act
        let document = try parse(petstore)
        let create = try #require(document.operations.first { $0.key == "operationId:createPet" })

        // Assert -- the generated text is kept so a later sync can tell an
        // untouched body from an edited one
        #expect(create.request.bodyMode == .raw)
        #expect(create.request.rawBodyType == .json)
        #expect(create.request.rawBody.contains(#""name" : "string""#))
        #expect(create.generatedBody == create.request.rawBody)
    }

    @Test func prefersTheAuthorsOwnExampleOverAGeneratedOne() throws {
        let document = try parse(#"""
            {
              "openapi": "3.0.0",
              "info": { "title": "X" },
              "paths": {
                "/login": {
                  "post": {
                    "requestBody": {
                      "content": {
                        "application/json": {
                          "schema": { "type": "object", "properties": { "user": { "type": "string" } } },
                          "example": { "user": "ada" }
                        }
                      }
                    }
                  }
                }
              }
            }
            """#)

        #expect(document.operations[0].request.rawBody.contains(#""user" : "ada""#))
    }

    @Test func readsASwagger2BodyParameterAndHostFields() throws {
        // Arrange -- Swagger 2 splits the server across host/basePath/schemes
        // and carries the body as a parameter
        let document = try parse(#"""
            {
              "swagger": "2.0",
              "info": { "title": "Legacy" },
              "host": "api.legacy.dev",
              "basePath": "/v2",
              "schemes": ["https"],
              "paths": {
                "/users": {
                  "post": {
                    "operationId": "addUser",
                    "parameters": [
                      { "name": "body", "in": "body",
                        "schema": { "$ref": "#/definitions/User" } }
                    ]
                  }
                }
              },
              "definitions": {
                "User": {
                  "type": "object",
                  "properties": { "email": { "type": "string", "format": "email" } }
                }
              }
            }
            """#)

        #expect(document.serverURL == "https://api.legacy.dev/v2")
        #expect(document.operations[0].request.rawBody.contains(#""email" : "user@example.com""#))
    }

    @Test func aFormBodyBecomesFormFields() throws {
        let document = try parse(#"""
            {
              "openapi": "3.0.0",
              "info": { "title": "X" },
              "paths": {
                "/upload": {
                  "post": {
                    "requestBody": {
                      "content": {
                        "application/x-www-form-urlencoded": {
                          "schema": {
                            "type": "object",
                            "required": ["file"],
                            "properties": {
                              "file": { "type": "string" },
                              "note": { "type": "string" }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
            """#)

        let request = document.operations[0].request
        #expect(request.bodyMode == .form)
        #expect(request.formFields.map(\.key) == ["file", "note"])
        #expect(request.formFields.first { $0.key == "file" }?.enabled == true)
    }

    // MARK: - Rejections

    @Test func rejectsYAMLWithAnActionableMessage() throws {
        // Arrange
        let yaml = """
            openapi: 3.0.0
            info:
              title: Petstore
            paths:
              /pets:
                get: {}
            """

        // Act / Assert
        let error = #expect(throws: SpecImportError.self) {
            _ = try OpenAPISpec.document(from: Data(yaml.utf8))
        }
        #expect(error?.errorDescription?.contains("YAML") == true)
        #expect(error?.recoverySuggestion?.contains("yq") == true)
    }

    @Test func rejectsJSONThatIsNotASpec() throws {
        let error = #expect(throws: SpecImportError.self) {
            _ = try OpenAPISpec.document(from: Data(#"{ "hello": "world" }"#.utf8))
        }
        #expect(error?.errorDescription?.contains("not an OpenAPI") == true)
    }

    @Test func rejectsASpecWithNoEndpoints() throws {
        #expect(throws: SpecImportError.self) {
            _ = try OpenAPISpec.document(
                from: Data(#"{ "openapi": "3.0.0", "info": {}, "paths": {} }"#.utf8)
            )
        }
    }

    @Test func saysSoWhenNoServerIsDeclared() throws {
        let document = try parse(#"""
            {
              "openapi": "3.0.0",
              "info": { "title": "X" },
              "paths": { "/health": { "get": {} } }
            }
            """#)

        #expect(document.serverURL.isEmpty)
        #expect(document.warnings.contains { $0.contains("no server URL") })
    }

    /// Re-reading the same document must not reshuffle the sidebar.
    @Test func operationOrderIsStableAcrossReads() throws {
        let first = try parse(petstore).operations.map(\.key)
        let second = try parse(petstore).operations.map(\.key)
        #expect(first == second)
    }
}
