import AppKit

enum TypstSyntaxColors {
    static func color(_ tag: String) -> NSColor? {
        switch tag {
        case "Comment": return .secondaryLabelColor
        case "Keyword", "Function": return .systemPurple
        case "String": return .systemGreen
        case "Number", "MathOperator", "MathDelimiter": return .systemOrange
        default: return nil
        }
    }
}
