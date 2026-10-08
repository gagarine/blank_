import Foundation

public extension ParsedSource {
    // Markup labels attach to document content. Label-valued expressions in
    // citations or code are not declarations of cross-reference targets.
    var markupLabelSpans: [ByteSpan] {
        var labels: [ByteSpan] = []
        func visit(_ node: SyntaxNode) {
            for child in node.children {
                if node.kind == "Markup", child.kind == "Label" {
                    labels.append(child.span)
                }
                visit(child)
            }
        }
        visit(tree)
        return labels
    }
}

public extension DocumentBuffer {
    var literalLabels: [String] {
        parsed.markupLabelSpans.compactMap { span in
            let literal = source.bytes(span)
            guard literal.hasPrefix("<"), literal.hasSuffix(">") else { return nil }
            return String(literal.dropFirst().dropLast())
        }
    }
}
