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

        // User-owned: name, auth, postResponseScript, scriptTimeoutSeconds and
        // order are deliberately absent from this function.

        let isUntouched = current.rawBody == (current.spec?.generatedBody ?? "")
        if isUntouched, current.bodyMode != .form {
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
