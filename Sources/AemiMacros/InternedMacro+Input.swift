import SwiftDiagnostics
import SwiftParser
import SwiftSyntax

extension InternedMacro {
    static func validatedBinding(
        from declaration: some DeclSyntaxProtocol,
        attribute node: AttributeSyntax
    ) throws -> PatternBindingSyntax {
        guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
            throw error(node, "@Interned can only be applied to a property")
        }

        guard varDecl.bindings.count == 1, let binding = varDecl.bindings.first else {
            throw error(node, "@Interned can only be applied to a single property")
        }

        guard binding.pattern.is(IdentifierPatternSyntax.self) else {
            throw error(node, "@Interned can only be applied to a named property")
        }

        guard binding.accessorBlock == nil else {
            throw error(node, "@Interned cannot be applied to properties with accessors or observers")
        }

        if let typeAnnotation = binding.typeAnnotation,
            !isStringType(typeAnnotation.type)
        {
            throw error(node, "@Interned can only be applied to String properties")
        }

        return binding
    }

    static func propertyLiteralValue(
        from attribute: AttributeSyntax,
        binding: PatternBindingSyntax
    ) throws -> String {
        if let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first?.expression
        {
            return try wrap(
                {
                    try literalValue(
                        from: first,
                        nonLiteralMessage: "@Interned requires a string literal (as argument or initializer)",
                        interpolationMessage: "@Interned does not support string interpolation"
                    )
                }, node: attribute)
        }

        if let initializer = binding.initializer?.value {
            return try wrap(
                {
                    try literalValue(
                        from: initializer,
                        nonLiteralMessage: "@Interned requires a string literal (as argument or initializer)",
                        interpolationMessage: "@Interned does not support string interpolation"
                    )
                }, node: attribute)
        }

        throw error(attribute, "@Interned requires a string literal (as argument or initializer)")
    }

    static func expressionInput(
        from node: some FreestandingMacroExpansionSyntax,
        backend: InternedObfuscationBackend
    ) throws -> InternedExpressionInput {
        let macroName = macroDisplayName(for: node)

        guard let firstArgument = node.arguments.first else {
            throw error(node, "\(macroName) requires a string literal or array literal of strings")
        }

        guard firstArgument.label == nil else {
            throw error(node, "\(macroName) requires an unlabeled value argument")
        }

        let strategy = try strategy(from: node.arguments.dropFirst(), node: node, macroName: macroName)

        if let array = firstArgument.expression.as(ArrayExprSyntax.self) {
            let values = try arrayLiteralValues(from: array, node: node, macroName: macroName)
            let expressions = values.map {
                InternedObfuscation.make(for: $0, strategy: strategy, backend: backend).expressionSource
            }
            return InternedExpressionInput(expressionSource: "[\(expressions.joined(separator: ", "))]")
        }

        let value = try wrap(
            {
                try literalValue(
                    from: firstArgument.expression,
                    nonLiteralMessage: "\(macroName) requires a string literal or array literal of strings",
                    interpolationMessage: "\(macroName) does not support string interpolation"
                )
            }, node: node)

        return InternedExpressionInput(
            expressionSource: InternedObfuscation.make(for: value, strategy: strategy, backend: backend)
                .expressionSource
        )
    }

    static func strategy(
        from arguments: LabeledExprListSyntax.SubSequence,
        node: some SyntaxProtocol,
        macroName: String
    ) throws -> InternedObfuscationStrategy {
        guard let argument = arguments.first else {
            return .standard
        }

        guard arguments.count == 1 else {
            throw error(node, "\(macroName) supports at most one trailing strategy argument")
        }

        guard argument.label?.text == "strategy" else {
            throw error(node, "\(macroName) only supports a trailing 'strategy:' argument")
        }

        guard let memberAccess = argument.expression.as(MemberAccessExprSyntax.self) else {
            throw error(node, "\(macroName) supports only .standard and .layered strategies")
        }

        switch memberAccess.declName.baseName.text {
            case "standard":
                return .standard
            case "layered":
                return .layered
            default:
                throw error(node, "\(macroName) supports only .standard and .layered strategies")
        }
    }

    static func arrayLiteralValues(
        from array: ArrayExprSyntax,
        node: some SyntaxProtocol,
        macroName: String
    ) throws -> [String] {
        try array.elements.map { element in
            try wrap(
                {
                    try literalValue(
                        from: element.expression,
                        nonLiteralMessage: "\(macroName) array elements must all be string literals",
                        interpolationMessage: "\(macroName) array elements do not support string interpolation"
                    )
                }, node: node)
        }
    }

    static func literalValue(
        from expr: ExprSyntax,
        nonLiteralMessage: String,
        interpolationMessage: String
    ) throws -> String {
        guard let literal = expr.as(StringLiteralExprSyntax.self) else {
            throw LiteralValueError.message(nonLiteralMessage)
        }

        if let value = literal.representedLiteralValue {
            return value
        }

        if literal.segments.contains(where: { segment in
            if case .expressionSegment = segment {
                return true
            }
            return false
        }) {
            throw LiteralValueError.message(interpolationMessage)
        }

        throw LiteralValueError.message(nonLiteralMessage)
    }

    static func isStringType(_ type: TypeSyntax) -> Bool {
        let text = type.trimmed.description.filter { !$0.isWhitespace }
        return text == "String" || text == "Swift.String"
    }

    static func backend(for node: some FreestandingMacroExpansionSyntax) -> InternedObfuscationBackend {
        switch node.macroName.text {
            case "InlinedInterned":
                .inlined
            default:
                .shared
        }
    }

    static func macroDisplayName(for node: some FreestandingMacroExpansionSyntax) -> String {
        "#\(node.macroName.text)"
    }

    static func error(_ node: some SyntaxProtocol, _ message: String) -> DiagnosticsError {
        macroError(node, domain: "InternedStrings", message)
    }
}

private enum LiteralValueError: Error {
    case message(String)
}

extension InternedMacro {
    static func wrap(_ operation: () throws -> String, node: some SyntaxProtocol) throws -> String {
        do {
            return try operation()
        } catch let LiteralValueError.message(message) {
            throw error(node, message)
        }
    }
}
