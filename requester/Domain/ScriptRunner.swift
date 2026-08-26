import Foundation
import JavaScriptCore
import Synchronization

/// Runs a post-response script in a throwaway JavaScript context.
///
/// The script sees a `response` object (`statusCode` / `headers` / `text` /
/// `json()`), a `variables` object to write into, and `console.log`. Only
/// JSON-safe values cross back out.
///
/// This is a crash/hang-safety boundary, not a security sandbox -- the threat
/// model is "do not let a runaway script freeze the app" (a single local user),
/// not "defend against a malicious script author".
nonisolated struct ScriptRunner: Sendable {
    func run(
        source: String, response: ResponseRecord, timeoutSeconds: Double
    ) async -> ScriptResult {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ScriptResult(ran: false)
        }

        let payload = Payload(
            statusCode: response.statusCode,
            headers: Dictionary(
                response.headers.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }
            ),
            text: response.bodyText
        )

        // The evaluation runs on its own thread rather than the cooperative
        // pool: JavaScriptCore offers no way to interrupt a `while (true) {}`,
        // so on timeout that thread is abandoned. A dedicated thread keeps a
        // hung script from consuming a pool thread the app needs.
        //
        // Whichever finishes first -- the script or the timeout -- resumes the
        // continuation, and the other is dropped. This deliberately does *not*
        // use a task group: a group awaits all its children before returning,
        // so a child blocked forever on the abandoned thread would hang the
        // caller no matter how the group was cancelled.
        let timedOut = ScriptResult(
            ran: true,
            succeeded: false,
            error: "Script timed out after \(Self.formatted(timeoutSeconds))s."
        )

        return await withCheckedContinuation { continuation in
            let pending = Mutex<CheckedContinuation<ScriptResult, Never>?>(continuation)
            let finish: @Sendable (ScriptResult) -> Void = { result in
                let claimed = pending.withLock { slot -> CheckedContinuation<ScriptResult, Never>? in
                    defer { slot = nil }
                    return slot
                }
                claimed?.resume(returning: result)
            }

            let thread = Thread { finish(Self.evaluate(source: source, payload: payload)) }
            thread.stackSize = 4 << 20
            thread.start()

            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                finish(timedOut)
            }
        }
    }

    private static func formatted(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }

    private struct Payload: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var text: String
    }

    private static func evaluate(source: String, payload: Payload) -> ScriptResult {
        guard let context = JSContext() else {
            return ScriptResult(ran: true, succeeded: false, error: "Could not create a JS context.")
        }

        // JavaScriptCore hands results back through escaping callbacks, so
        // they accumulate in a box rather than in locals.
        let capture = Capture()

        context.exceptionHandler = { _, exception in
            capture.thrown = exception?.toString() ?? "Unknown JavaScript error"
        }

        let log: @convention(block) (JSValue) -> Void = { value in
            capture.output.append(value.toString() ?? "")
        }
        context.setObject(log, forKeyedSubscript: "__log" as NSString)

        context.setObject(payload.statusCode, forKeyedSubscript: "__statusCode" as NSString)
        context.setObject(payload.headers, forKeyedSubscript: "__headers" as NSString)
        context.setObject(payload.text, forKeyedSubscript: "__text" as NSString)

        // `response` is frozen so a script cannot corrupt the record it was
        // handed; `variables` is the one channel back out.
        context.evaluateScript(
            """
            var console = { log: __log, info: __log, warn: __log, error: __log };
            var variables = {};
            var response = Object.freeze({
                statusCode: __statusCode,
                headers: __headers,
                text: __text,
                json: function () { return JSON.parse(__text); }
            });
            """
        )

        context.evaluateScript(source, withSourceURL: URL(string: "postResponseScript.js"))

        if let thrown = capture.thrown {
            return ScriptResult(ran: true, succeeded: false, error: thrown)
        }

        var result = ScriptResult(ran: true, succeeded: true)
        result.variablesWritten = writtenVariables(from: context)
        result.output = capture.output.joined(separator: "\n")
        return result
    }

    private final class Capture {
        var output: [String] = []
        var thrown: String?
    }

    /// Every written value is stringified: a variable substituted into a URL or
    /// header is always text, so coercing here keeps what the script saw and
    /// what gets sent identical.
    private static func writtenVariables(from context: JSContext) -> [String: String] {
        guard let variables = context.objectForKeyedSubscript("variables"),
              let dictionary = variables.toDictionary() as? [String: Any]
        else { return [:] }

        return dictionary.reduce(into: [:]) { result, pair in
            guard !(pair.value is NSNull) else { return }
            if let text = pair.value as? String {
                result[pair.key] = text
            } else if let number = pair.value as? NSNumber {
                result[pair.key] = number.stringValue
            } else if let data = try? JSONSerialization.data(withJSONObject: pair.value) {
                result[pair.key] = String(decoding: data, as: UTF8.self)
            } else {
                result[pair.key] = String(describing: pair.value)
            }
        }
    }
}
