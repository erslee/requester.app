import SwiftUI

/// Auth tab: none / basic / bearer / API key, each with its own small form.
/// Fields that get `{{variable}}`-resolved at send time are tinted by whether
/// the name they reference is defined.
struct AuthTabView: View {
    @Binding var auth: AuthConfig
    var knownVariableNames: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $auth.type) {
                ForEach(AuthType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .fixedSize()

            switch auth.type {
            case .none:
                ContentUnavailableView(
                    "No Auth", systemImage: "lock.open",
                    description: Text("This request sends no credentials.")
                )

            case .basic:
                Form {
                    variableField("Username", text: $auth.basicUsername)
                    SecretField(title: "Password", text: $auth.basicPassword,
                                knownVariableNames: knownVariableNames)
                }
                .formStyle(.grouped)

            case .bearer:
                Form {
                    SecretField(title: "Token", text: $auth.bearerToken,
                                knownVariableNames: knownVariableNames)
                }
                .formStyle(.grouped)

            case .apiKey:
                Form {
                    LabeledContent("Key") {
                        TextField("X-API-Key", text: $auth.apiKeyName)
                            .font(.system(.body, design: .monospaced))
                    }
                    SecretField(title: "Value", text: $auth.apiKeyValue,
                                knownVariableNames: knownVariableNames)
                    Picker("Add to", selection: $auth.apiKeyIn) {
                        ForEach(APIKeyLocation.allCases) { location in
                            Text(location.rawValue.capitalized).tag(location)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Spacer()
        }
    }

    private func variableField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .font(.system(.body, design: .monospaced))
                .variableTint(text.wrappedValue, knownNames: knownVariableNames)
        }
    }
}

/// A credential field, masked by default with a click-to-reveal toggle --
/// rather than always masked (you cannot verify what is in it) or always
/// visible (a token on screen for anyone walking past).
struct SecretField: View {
    let title: String
    @Binding var text: String
    var knownVariableNames: Set<String> = []

    @State private var isRevealed = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Group {
                    if isRevealed {
                        TextField(title, text: $text)
                    } else {
                        SecureField(title, text: $text)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .variableTint(text, knownNames: knownVariableNames)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isRevealed ? "Hide" : "Reveal")
            }
        }
    }
}
