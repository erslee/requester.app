import Foundation
import Testing
@testable import requester

struct OpenAPISchemaExampleTests {
    /// Schemas are written as JSON here rather than as Swift dictionaries, so
    /// the tests read like the documents they stand for.
    private func document(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private func generate(
        _ schemaJSON: String, in documentJSON: String = "{}"
    ) -> OpenAPISchemaExample.Generated {
        OpenAPISchemaExample.json(for: document(schemaJSON), in: document(documentJSON))
    }

    // MARK: - Placeholders

    @Test func buildsAnObjectFromItsProperties() {
        // Arrange / Act
        let generated = generate(#"""
            {
              "type": "object",
              "properties": {
                "name": { "type": "string" },
                "age": { "type": "integer" },
                "active": { "type": "boolean" }
              }
            }
            """#)

        // Assert -- sorted keys, so the text is stable
        #expect(generated.text == """
            {
              "active" : false,
              "age" : 0,
              "name" : "string"
            }
            """)
        #expect(generated.warnings.isEmpty)
    }

    @Test func prefersAnExplicitExampleOverAPlaceholder() {
        let generated = generate(#"""
            {
              "type": "object",
              "properties": {
                "email": { "type": "string", "example": "ada@example.com" },
                "plan": { "type": "string", "enum": ["free", "pro"] },
                "seats": { "type": "integer", "default": 5 }
              }
            }
            """#)

        #expect(generated.text.contains(#""email" : "ada@example.com""#))
        #expect(generated.text.contains(#""plan" : "free""#))
        #expect(generated.text.contains(#""seats" : 5"#))
    }

    @Test func shapesAStringToItsFormat() {
        let generated = generate(#"""
            {
              "type": "object",
              "properties": {
                "createdAt": { "type": "string", "format": "date-time" },
                "id": { "type": "string", "format": "uuid" },
                "contact": { "type": "string", "format": "email" }
              }
            }
            """#)

        #expect(generated.text.contains(#""createdAt" : "2026-01-01T00:00:00Z""#))
        #expect(generated.text.contains(#""id" : "00000000-0000-0000-0000-000000000000""#))
        #expect(generated.text.contains(#""contact" : "user@example.com""#))
    }

    @Test func emitsOneElementForAnArray() {
        let generated = generate(#"{ "type": "array", "items": { "type": "string" } }"#)
        #expect(generated.text == """
            [
              "string"
            ]
            """)
    }

    /// A field the server only ever sends back has no place in a request body.
    @Test func leavesOutReadOnlyProperties() {
        let generated = generate(#"""
            {
              "type": "object",
              "properties": {
                "id": { "type": "string", "readOnly": true },
                "title": { "type": "string" }
              }
            }
            """#)

        #expect(!generated.text.contains("\"id\""))
        #expect(generated.text.contains("\"title\""))
    }

    /// A schema with properties but no declared `type` is an object in practice.
    @Test func infersObjectWhenTheTypeIsMissing() {
        let generated = generate(#"{ "properties": { "name": { "type": "string" } } }"#)
        #expect(generated.text.contains(#""name" : "string""#))
    }

    // MARK: - References

    @Test func resolvesAnOpenAPI3ComponentReference() {
        let generated = generate(
            ##"{ "$ref": "#/components/schemas/User" }"##,
            in: #"""
                {
                  "components": {
                    "schemas": {
                      "User": {
                        "type": "object",
                        "properties": { "name": { "type": "string" } }
                      }
                    }
                  }
                }
                """#
        )

        #expect(generated.text.contains(#""name" : "string""#))
        #expect(generated.warnings.isEmpty)
    }

    @Test func resolvesASwagger2DefinitionReference() {
        let generated = generate(
            ##"{ "$ref": "#/definitions/User" }"##,
            in: #"""
                {
                  "definitions": {
                    "User": {
                      "type": "object",
                      "properties": { "name": { "type": "string" } }
                    }
                  }
                }
                """#
        )

        #expect(generated.text.contains(#""name" : "string""#))
    }

    /// The test this whole guard exists for: without it, the generator recurses
    /// until the stack gives out on a perfectly valid document.
    @Test func aSelfReferentialSchemaTerminates() {
        let generated = generate(
            ##"{ "$ref": "#/components/schemas/Node" }"##,
            in: #"""
                {
                  "components": {
                    "schemas": {
                      "Node": {
                        "type": "object",
                        "properties": {
                          "label": { "type": "string" },
                          "children": {
                            "type": "array",
                            "items": { "$ref": "#/components/schemas/Node" }
                          }
                        }
                      }
                    }
                  }
                }
                """#
        )

        #expect(generated.text.contains(#""label" : "string""#))
        #expect(generated.text.contains("children"))
        #expect(generated.warnings.contains { $0.contains("refers to itself") })
    }

    @Test func mutuallyRecursiveSchemasTerminate() {
        let generated = generate(
            ##"{ "$ref": "#/components/schemas/A" }"##,
            in: #"""
                {
                  "components": {
                    "schemas": {
                      "A": {
                        "type": "object",
                        "properties": { "b": { "$ref": "#/components/schemas/B" } }
                      },
                      "B": {
                        "type": "object",
                        "properties": { "a": { "$ref": "#/components/schemas/A" } }
                      }
                    }
                  }
                }
                """#
        )

        #expect(generated.text.contains("\"b\""))
        #expect(generated.warnings.contains { $0.contains("refers to itself") })
    }

    @Test func reportsAReferenceIntoAnotherFileRatherThanFetchingIt() {
        let generated = generate(#"{ "$ref": "./common.json#/User" }"#)

        #expect(generated.text == "null")
        #expect(generated.warnings.contains { $0.contains("points outside this document") })
    }

    @Test func reportsAReferenceThatIsNotInTheDocument() {
        let generated = generate(##"{ "$ref": "#/components/schemas/Missing" }"##)
        #expect(generated.warnings.contains { $0.contains("is not in this document") })
    }

    // MARK: - Composition

    @Test func mergesAllOfIntoOneShape() {
        let generated = generate(
            #"""
                {
                  "allOf": [
                    { "$ref": "#/components/schemas/Base" },
                    { "type": "object", "properties": { "extra": { "type": "boolean" } } }
                  ]
                }
                """#,
            in: #"""
                {
                  "components": {
                    "schemas": {
                      "Base": {
                        "type": "object",
                        "properties": { "id": { "type": "integer" } }
                      }
                    }
                  }
                }
                """#
        )

        #expect(generated.text.contains(#""id" : 0"#))
        #expect(generated.text.contains(#""extra" : false"#))
    }

    @Test func takesTheFirstBranchOfOneOfAndSaysSo() {
        let generated = generate(#"""
            {
              "oneOf": [
                { "type": "object", "properties": { "card": { "type": "string" } } },
                { "type": "object", "properties": { "iban": { "type": "string" } } }
              ]
            }
            """#)

        #expect(generated.text.contains("card"))
        #expect(!generated.text.contains("iban"))
        #expect(generated.warnings.contains { $0.contains("alternative shapes") })
    }

    // MARK: - Nothing to build

    @Test func aMissingSchemaProducesNoBody() {
        let generated = OpenAPISchemaExample.json(for: nil, in: [:])
        #expect(generated.text.isEmpty)
        #expect(generated.warnings.isEmpty)
    }
}
