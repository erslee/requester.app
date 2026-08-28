import Foundation

/// Works out what a re-read of a spec changes, without changing anything.
///
/// Pure on purpose: every rule about what a refresh does to work already done
/// is decided here, where it can be tested directly, rather than inside the
/// code that writes files.
///
/// The rule, in one line: **the spec owns the shape, you own everything else.**
/// Method, URL, query parameters and spec-declared headers are rewritten from
/// the document on every sync. Name, auth, and the post-response script are
/// never touched once the request exists. The body is the single exception, and
/// the reason `SpecLink.generatedBody` is stored -- see `merged`.
nonisolated enum SpecSync {
    /// What separated a tag from an operation name before folders existed.
    private static let legacyFolderSeparator = " / "

    struct Plan: Sendable {
        /// New operations, in document order, ready to be written.
        var added: [OpenAPISpec.Operation] = []
        /// Existing requests with spec-owned fields brought up to date.
        var updated: [APIRequest] = []
        /// Requests whose operation reappeared after having been removed.
        var restored: [APIRequest] = []
        /// Requests whose operation is gone: tombstoned, never deleted.
        var removed: [APIRequest] = []
        /// Matched and already correct -- nothing to write.
        var unchangedCount = 0

        var isEmpty: Bool {
            added.isEmpty && updated.isEmpty && restored.isEmpty && removed.isEmpty
        }

        /// Everything that needs writing, so the caller has one list to apply.
        var writes: [APIRequest] { updated + restored + removed }
    }

    /// Compares what is on disk with what the document now says.
    ///
    /// - Parameters:
    ///   - existing: every request in the project, spec-linked or not.
    ///   - incoming: the operations the document describes.
    static func plan(
        existing: [APIRequest], incoming: [OpenAPISpec.Operation], now: Date = Date()
    ) -> Plan {
        // A request with no spec link was made by hand. It is not matched, not
        // updated, and above all not tombstoned when it is absent from the
        // document -- it was never in it.
        var byKey: [String: APIRequest] = [:]
        for request in existing {
            guard let key = request.spec?.key else { continue }
            // A duplicate key can only come from a hand-edited file. Keeping the
            // first and leaving the rest unmatched is safer than picking one to
            // overwrite.
            if byKey[key] == nil { byKey[key] = request }
        }

        var plan = Plan()
        var seen: Set<String> = []

        for operation in incoming {
            seen.insert(operation.key)

            guard let current = byKey[operation.key] else {
                plan.added.append(operation)
                continue
            }

            var next = merged(operation, into: current)
            let wasRemoved = current.spec?.isRemoved == true
            // An operation that comes back is the request that was already
            // there, un-tombstoned in place. Adding a second one would leave
            // the user with a duplicate and orphan its history.
            next.spec?.removedAt = nil

            if wasRemoved {
                plan.restored.append(next)
            } else if next.editableContent != current.editableContent
                || next.spec != current.spec {
                plan.updated.append(next)
            } else {
                plan.unchangedCount += 1
            }
        }

        for (key, request) in byKey where !seen.contains(key) {
            // Already tombstoned from an earlier sync: leave it exactly as it
            // is, so the date keeps saying when it actually disappeared.
            guard request.spec?.isRemoved != true else { continue }
            var tombstoned = request
            tombstoned.spec?.removedAt = now
            plan.removed.append(tombstoned)
        }

        return plan
    }

    /// Applies the spec's fields over an existing request, preserving the
    /// user's.
    ///
    /// The body deserves its own explanation. Overwriting it always would
    /// discard real request payloads on every refresh; never overwriting it
    /// would mean a changed schema never reaches the request. So the example
    /// generated last time is remembered, and the body is regenerated only when
    /// what is there still matches it -- i.e. the user has not touched it. The
    /// first edit makes it theirs permanently.
    static func merged(_ operation: OpenAPISpec.Operation, into current: APIRequest) -> APIRequest {
        var result = current

        // Spec-owned.
        result.method = operation.request.method
        result.url = operation.request.url
        result.params = reconciled(
            spec: operation.request.params, current: current.params
        )
        result.headers = reconciled(
            spec: operation.request.headers, current: current.headers
        )

        // User-owned: name, folder, auth, postResponseScript,
        // scriptTimeoutSeconds and order are deliberately absent from this
        // function. The document's tag places a request when it is first
        // created and never moves it again -- where the user filed something is
        // theirs, exactly like what they named it.
        //
        // The one exception is the shape this app wrote before it had folders,
        // where the tag was glued onto the name as "Users / listUsers". That is
        // unfolded here: only when the request is still in no folder *and* its
        // name is exactly the prefix this document's tag would have produced,
        // so a request the user has since renamed or filed is left alone.
        if result.folder.isEmpty,
           let tag = operation.request.folder.first,
           current.name.hasPrefix(tag + Self.legacyFolderSeparator) {
            result.folder = operation.request.folder
            result.name = String(
                current.name.dropFirst(tag.count + Self.legacyFolderSeparator.count)
            )
        }

        let isUntouched = current.rawBody == (current.spec?.generatedBody ?? "")

        if operation.request.bodyMode == .form {
            // A form body has no generated text to compare against, so the
            // "untouched?" test above cannot speak for it. Its fields are
            // reconciled the way parameters are instead: the spec decides which
            // fields exist, the user keeps whatever they typed into them.
            // Excluding form bodies from the sync altogether -- as this first
            // did -- froze their fields forever, so a field added to the
            // document never reached the request.
            result.bodyMode = .form
            result.formFields = reconciled(
                spec: operation.request.formFields, current: current.formFields
            )
        } else if isUntouched {
            result.bodyMode = operation.request.bodyMode
            result.rawBody = operation.request.rawBody
            result.rawBodyType = operation.request.rawBodyType
            result.formFields = operation.request.formFields
        }

        result.spec = SpecLink(
            key: operation.key,
            removedAt: current.spec?.removedAt,
            // Follows the body: remembering an example that was not applied
            // would make the next sync think an edited body was untouched.
            generatedBody: isUntouched ? operation.generatedBody : (current.spec?.generatedBody ?? "")
        )
        return result
    }

    /// Merges the form-field table, on the same principle as the parameter one.
    private static func reconciled(
        spec: [FormField], current: [FormField]
    ) -> [FormField] {
        let currentByKey = Dictionary(
            current.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }
        )

        return spec.map { field in
            guard let existing = currentByKey[field.key] else { return field }
            var merged = field
            merged.value = existing.value
            merged.enabled = existing.enabled
            // A file the user attached is theirs, and the spec has no opinion
            // about which file it should be.
            merged.isFile = existing.isFile
            merged.filePath = existing.filePath
            merged.contentType = existing.contentType
            return merged
        }
    }

    /// Merges one parameter table.
    ///
    /// The spec decides which rows exist and what they are called; the user
    /// decides what goes in them and whether they are switched on. So a row
    /// still in the document keeps its current value and enabled state, a new
    /// row arrives as the spec describes it, and a row the document dropped
    /// goes with it.
    private static func reconciled(
        spec: [KeyValueItem], current: [KeyValueItem]
    ) -> [KeyValueItem] {
        let currentByKey = Dictionary(current.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        return spec.map { item in
            guard let existing = currentByKey[item.key] else { return item }
            var merged = item
            merged.value = existing.value
            merged.enabled = existing.enabled
            return merged
        }
    }
}
