import Foundation

/// Which kind of document a project's spec source points at.
///
/// Deliberately not an enum with associated values: the editor binds directly
/// to `SpecSource`'s fields, and a flat struct with a discriminator is the
/// shape the rest of the app already uses for this (see `AuthConfig`).
nonisolated enum SpecSourceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case url
    case file

    var id: String { rawValue }

    var label: String {
        switch self {
        case .url: "Link"
        case .file: "File"
        }
    }
}

/// Where a project's OpenAPI document comes from, and when it was last read.
///
/// A project has at most one. Both kinds refresh through the same pipeline --
/// only the step producing the bytes differs -- so re-fetching a link and
/// re-uploading a file merge identically.
nonisolated struct SpecSource: Codable, Sendable, Hashable {
    var kind: SpecSourceKind = .url

    /// Where to fetch the document, for `.url`. Resolved through
    /// `VariableResolver` at fetch time, so `{{host}}/openapi.json` works the
    /// way it does in any other field.
    var url: String = ""

    /// Sent with the fetch, for a spec behind a token or an API key. Ignored
    /// by `.file`, which has nothing to fetch.
    var headers: [KeyValueItem] = []

    /// The name of the file last uploaded, for `.file` -- shown so the source
    /// is identifiable. The file itself is not retained and no bookmark is kept
    /// to it: refreshing a file-backed spec means picking a file again, which
    /// is also how the user asked for it to work.
    var fileName: String = ""

    /// `nil` until the first successful sync. A source that has never synced
    /// is still a valid source -- it just has nothing to show a date for.
    var lastSyncedAt: Date?

    init(kind: SpecSourceKind = .url) {
        self.kind = kind
    }

    /// What the UI calls this source. Falls back rather than showing an empty
    /// label, since a source can exist before it has ever been read.
    var displayName: String {
        switch kind {
        case .url: url.isEmpty ? "Untitled link" : url
        case .file: fileName.isEmpty ? "Uploaded file" : fileName
        }
    }
}

/// Ties one saved request back to the spec operation it came from.
///
/// Present only on requests a spec created. A request made by hand has `nil`
/// here and is never touched by a sync.
nonisolated struct SpecLink: Codable, Sendable, Hashable {
    /// Identity across syncs: the operation's `operationId` when the spec gives
    /// one, otherwise `"GET /users/{id}"`. This is what decides whether an
    /// operation is the same one as last time, so it is matched on rather than
    /// the request's name or URL, both of which the user may change.
    var key: String

    /// Set when the operation stopped appearing in the spec, cleared if it
    /// comes back. The request itself is kept and stays fully usable -- open,
    /// edit, send, and all of its history -- it is only marked. Nothing in this
    /// app deletes a request the user did not ask to delete.
    var removedAt: Date?

    /// The example body this operation's schema generated at the last sync.
    ///
    /// The merge rule compares the request's current body against this to tell
    /// "still the generated example, safe to regenerate" from "edited by hand,
    /// never overwrite". Without it there is no way to distinguish the two, and
    /// a refresh would have to either clobber real request bodies or never
    /// update any of them.
    var generatedBody: String = ""

    init(key: String, removedAt: Date? = nil, generatedBody: String = "") {
        self.key = key
        self.removedAt = removedAt
        self.generatedBody = generatedBody
    }

    var isRemoved: Bool { removedAt != nil }
}
