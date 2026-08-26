import SwiftUI

/// Scripts tab: the post-response script and its timeout.
///
/// The script is JavaScript, evaluated after the response arrives (see
/// `ScriptRunner`). It receives a `response` object and a `variables` object
/// to write into, and whatever it writes becomes project variables.
struct ScriptsTabView: View {
    @Binding var draft: APIRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("POST-RESPONSE SCRIPT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                LabeledContent("Timeout") {
                    HStack(spacing: 4) {
                        TextField(
                            "",
                            value: $draft.scriptTimeoutSeconds,
                            format: .number.precision(.fractionLength(0...1))
                        )
                        .frame(width: 46)
                        .multilineTextAlignment(.trailing)
                        Stepper(
                            "", value: $draft.scriptTimeoutSeconds, in: 0.5...120, step: 0.5
                        )
                        .labelsHidden()
                        Text("s").foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }

            PlaceholderCodeEditor(
                text: $draft.postResponseScript,
                placeholder: """
                    // Runs after the response arrives.
                    // variables.token = response.json().access_token
                    """
            )

            DisclosureGroup("What the script can use") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Self.apiReference, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }

    private static let apiReference = [
        "response.statusCode      // 200",
        "response.headers         // { \"content-type\": \"application/json\" }",
        "response.text            // the raw body",
        "response.json()          // the body parsed as JSON",
        "variables.name = value   // saved as a project variable",
        "console.log(…)           // shown in the response panel",
    ]
}
