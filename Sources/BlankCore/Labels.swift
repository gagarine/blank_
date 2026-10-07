import Foundation

public extension DocumentBuffer {
    // Markup labels attach to document content. Label-valued expressions in
    // citations or code are not declarations of cross-reference targets.
    var literalLabels: [String] {
        var labels: [String] = []
        func visit(_ node: SyntaxNode) {
            for child in node.children {
                if node.kind == "Markup", child.kind == "Label" {
                    let literal = source.bytes(child.span)
                    if literal.hasPrefix("<"), literal.hasSuffix(">") {
                        labels.append(String(literal.dropFirst().dropLast()))
                    }
                }
                visit(child)
            }
        }
        visit(parsed.tree)
        return labels
    }
}
