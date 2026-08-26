import SwiftUI

/// Whether the `{{variables}}` in a piece of text will resolve.
nonisolated enum VariableStatus {
    case none
    case valid
    case invalid

    /// Whole-text classification, for places that can only show one colour (a
    /// table cell, a text field). A mix counts as invalid, since that is the
    /// actionable signal: something in here will not resolve.
    static func classify(_ text: String, knownNames: Set<String>) -> VariableStatus {
        let names = VariableResolver.names(in: text)
        if names.isEmpty { return .none }
        return names.allSatisfy(knownNames.contains) ? .valid : .invalid
    }

    var tint: Color? {
        switch self {
        case .none: nil
        case .valid: Palette.valid
        case .invalid: Palette.invalid
        }
    }
}

/// Tints a field or cell according to whether its `{{variables}}` are defined.
struct VariableTint: ViewModifier {
    let text: String
    let knownNames: Set<String>

    func body(content: Content) -> some View {
        let tint = VariableStatus.classify(text, knownNames: knownNames).tint
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill((tint ?? .clear).opacity(0.11))
                    .strokeBorder((tint ?? .clear).opacity(0.6))
            )
    }
}

extension View {
    func variableTint(_ text: String, knownNames: Set<String>) -> some View {
        modifier(VariableTint(text: text, knownNames: knownNames))
    }
}
