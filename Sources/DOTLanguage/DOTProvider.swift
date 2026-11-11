import Grammar
import IncrementalParsing
import LanguageTooling
import Lexer
import Parser

public struct DOTProvider: LanguageToolingProvider {
    public let descriptor = LanguageProviderDescriptor(
        id: "dot", displayName: "Graphviz DOT",
        fileExtensions: ["dot", "gv"], distribution: .bundledPermanent,
        capabilities: [
            .syntaxHighlighting, .incrementalAnalysis, .diagnostics, .recovery,
        ])

    public init() {}
    public func makeToolingSession() -> any LanguageToolingSession {
        DOTProviderSession()
    }
}

public actor DOTProviderSession: LanguageToolingSession {
    private var tokenizer: GrammarIncrementalTokenizer
    private var text: String?
    private var revision: SourceRevision?
    private var elements: [GrammarLexicalElement] = []

    public init() {
        do {
            tokenizer = RestartAndConvergeTokenizer(
                scanner: try GrammarDrivenLexer(specification: DOTLexicon.specification))
        } catch {
            preconditionFailure("Invalid DOT lexical specification: \(error)")
        }
    }

    public func analyze(_ snapshot: SourceSnapshot, change: SourceChange?) async throws
        -> LanguageProviderAnalysis {
        if let change, change.after != snapshot {
            throw LanguageProviderError.inconsistentChange
        }
        let lexed = tokenizer.tokenize(snapshot: snapshot, change: change)
        text = snapshot.text
        revision = snapshot.revision
        elements = lexed.output.elements
        let significant = lexed.output.tokens.filter { $0.kind != "$EOF" }
        var structure = DOTStructureValidator(tokens: significant)
        structure.validate(endOffset: snapshot.text.utf16.count)
        let metrics = lexed.metrics

        return LanguageProviderAnalysis(
            languageID: "dot", revision: snapshot.revision,
            tokens: DOTLexicon.providerTokens(lexed.output.elements),
            diagnostics: lexed.output.diagnostics.map {
                .init(
                    severity: .error, message: $0.message,
                    range: .init($0.range.lowerBound, $0.range.upperBound))
            } + structure.diagnostics,
            recoveryEdits: structure.recoveryEdits,
            operations: [
                .init(operation: "lexing", evidence: DOTLexicon.evidence(metrics)),
                .init(operation: "parsing", evidence: .init(
                    strategy: .full,
                    measurements: [.init(
                        dimension: .init(rawValue: "dotStatements"),
                        reused: 0, rebuilt: structure.statementCount,
                        strategy: "dot-structural-validation")]))
            ])
    }

    public func semanticTokens() async throws -> ToolingSemanticTokensResult {
        guard let text, let revision else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        let map = SourceLineMap(text)
        let tokens = DOTLexicon.providerTokens(elements).compactMap {
            token -> ToolingSemanticToken? in
            guard let type = DOTLexicon.semanticType(token.classification) else {
                return nil
            }
            return .init(range: map.toolingRange(token.range), type: type)
        }
        return SemanticTokenEncoder.encode(tokens, resultID: "dot:\(revision.rawValue)")
    }
}

private enum DOTLexicon {
    static let specification = LexicalSpecification(rules: [
        .init(name: "WHITESPACE", matcher: .regularExpression(#"\s+"#), channel: .trivia),
        .init(name: "LINE_COMMENT", matcher: .lineComment("//"), channel: .trivia),
        .init(name: "HASH_COMMENT", matcher: .lineComment("#"), channel: .trivia),
        .init(name: "BLOCK_COMMENT", matcher: .blockComment(open: "/*", close: "*/"), channel: .trivia),
        .init(name: "STRICT", matcher: .caseInsensitiveLiteral("strict"), priority: -1),
        .init(name: "DIGRAPH", matcher: .caseInsensitiveLiteral("digraph"), priority: -1),
        .init(name: "GRAPH", matcher: .caseInsensitiveLiteral("graph"), priority: -1),
        .init(name: "SUBGRAPH", matcher: .caseInsensitiveLiteral("subgraph"), priority: -1),
        .init(name: "NODE", matcher: .caseInsensitiveLiteral("node"), priority: -1),
        .init(name: "EDGE", matcher: .caseInsensitiveLiteral("edge"), priority: -1),
        .init(name: "STRING", matcher: .regularExpression(#"\"(?:\\.|[^\"\\])*\""#)),
        .init(name: "HTML", matcher: .regularExpression(#"<[^\r\n>]*(?:>[^\r\n<]*)*>"#)),
        .init(name: "NUMBER", matcher: .regularExpression(#"-?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)"#)),
        .init(name: "ID", matcher: .regularExpression(#"[A-Za-z_\u0080-\uFFFF][A-Za-z0-9_\u0080-\uFFFF]*"#)),
        .init(name: "DIRECTED_EDGE", matcher: .literal("->")),
        .init(name: "UNDIRECTED_EDGE", matcher: .literal("--")),
        .init(name: "LBRACE", matcher: .literal("{")),
        .init(name: "RBRACE", matcher: .literal("}")),
        .init(name: "LBRACKET", matcher: .literal("[")),
        .init(name: "RBRACKET", matcher: .literal("]")),
        .init(name: "EQUAL", matcher: .literal("=")),
        .init(name: "COLON", matcher: .literal(":")),
        .init(name: "SEMICOLON", matcher: .literal(";")),
        .init(name: "COMMA", matcher: .literal(",")),
    ])

    static func evidence(_ metrics: RestartAndConvergeMetrics)
        -> IncrementalExecutionEvidence {
        .init(
            strategy: metrics.incremental ? .incremental : .full,
            measurements: [.init(
                dimension: .tokens,
                reused: metrics.reusedPrefixTokenCount + metrics.reusedSuffixTokenCount,
                rebuilt: metrics.generatedTokenCount,
                strategy: metrics.incremental
                    ? "restart-and-converge" : "full-tokenization")])
    }

    static func providerTokens(_ elements: [GrammarLexicalElement])
        -> [LanguageProviderToken] {
        elements.compactMap { element in
            let classification: String
            switch element.kind {
            case .invalid: classification = "invalid"
            case .trivia: classification = "comment"
            case .token(let kind):
                switch kind {
                case "STRICT", "DIGRAPH", "GRAPH", "SUBGRAPH", "NODE", "EDGE":
                    classification = "keyword"
                case "STRING", "HTML": classification = "string"
                case "NUMBER": classification = "number"
                case "ID": classification = "identifier"
                default: classification = "operator"
                }
            }
            return .init(
                range: .init(element.range.lowerBound, element.range.upperBound),
                classification: classification)
        }
    }

    static func semanticType(_ classification: String)
        -> ToolingSemanticTokenType? {
        switch classification {
        case "comment": .comment
        case "keyword": .keyword
        case "string": .string
        case "number": .number
        case "identifier": .variable
        case "operator": .operatorToken
        default: nil
        }
    }
}

private struct DOTStructureValidator {
    let tokens: [GrammarLexicalToken]
    var diagnostics: [LanguageProviderDiagnostic] = []
    var recoveryEdits: [LanguageProviderRecoveryEdit] = []
    var statementCount = 0

    mutating func validate(endOffset: Int) {
        var index = 0
        if kind(at: index) == "STRICT" { index += 1 }
        let graphKind = kind(at: index)
        if graphKind == "GRAPH" || graphKind == "DIGRAPH" {
            index += 1
        } else {
            insert("graph", at: index, offset: range(at: index, fallback: endOffset).location,
                   message: "Expected 'graph' or 'digraph'")
        }
        if ["ID", "STRING", "NUMBER"].contains(kind(at: index)) { index += 1 }
        if kind(at: index) != "LBRACE" {
            insert("{", at: index, offset: range(at: index, fallback: endOffset).location,
                   message: "Expected '{' before graph statements")
        }

        let delimiterTokens = tokens.map {
            DelimiterToken(
                id: $0.id, kind: $0.kind,
                range: SourceRange($0.range.lowerBound, $0.range.upperBound))
        }
        let balanced = BalancedDelimiterRecovery<String, String>(pairs: [
            .init(open: "LBRACE", close: "RBRACE"),
            .init(open: "LBRACKET", close: "RBRACKET"),
        ]).validate(delimiterTokens, endOffset: endOffset)
        diagnostics += balanced.diagnostics.map {
            .init(
                severity: $0.severity, message: $0.message, range: $0.range,
                expected: $0.expected.map(DOTLexicon.spelling))
        }
        recoveryEdits += balanced.repairs.compactMap(providerEdit)

        let expectedEdge = graphKind == "GRAPH" ? "UNDIRECTED_EDGE" : "DIRECTED_EDGE"
        for (tokenIndex, token) in tokens.enumerated() {
            if token.kind == "SEMICOLON" { statementCount += 1 }
            if token.kind == "DIRECTED_EDGE" || token.kind == "UNDIRECTED_EDGE",
               token.kind != expectedEdge {
                diagnostics.append(.init(
                    severity: .error,
                    message: "Edge operator does not match graph kind",
                    range: .init(token.range.lowerBound, token.range.upperBound),
                    expected: [DOTLexicon.spelling(expectedEdge)]))
                recoveryEdits.append(.delete(
                    terminal: DOTLexicon.spelling(token.kind), atToken: tokenIndex))
                recoveryEdits.append(.insert(
                    terminal: DOTLexicon.spelling(expectedEdge), atToken: tokenIndex))
            }
        }
        if statementCount == 0 && tokens.contains(where: { $0.kind == "LBRACE" }) {
            statementCount = 1
        }
    }

    private func kind(at index: Int) -> String? {
        tokens.indices.contains(index) ? tokens[index].kind : nil
    }

    private func range(at index: Int, fallback: Int) -> SourceRange {
        guard tokens.indices.contains(index) else {
            return .init(location: fallback, length: 0)
        }
        return .init(tokens[index].range.lowerBound, tokens[index].range.upperBound)
    }

    private mutating func insert(
        _ terminal: String, at index: Int, offset: Int, message: String
    ) {
        diagnostics.append(.init(
            severity: .error, message: message,
            range: .init(location: offset, length: 0), expected: [terminal]))
        recoveryEdits.append(.insert(terminal: terminal, atToken: index))
    }

    private func providerEdit(
        _ repair: RecoveryAction<String, String>
    ) -> LanguageProviderRecoveryEdit? {
        switch repair {
        case .insert(let kind, let offset):
            let index = tokens.firstIndex { $0.range.lowerBound >= offset } ?? tokens.count
            return .insert(terminal: DOTLexicon.spelling(kind), atToken: index)
        case .delete(let id, _):
            guard let index = tokens.firstIndex(where: { $0.id == id }) else { return nil }
            return .delete(terminal: DOTLexicon.spelling(tokens[index].kind), atToken: index)
        case .replace, .skip: return nil
        }
    }
}

private extension DOTLexicon {
    static func spelling(_ kind: String) -> String {
        switch kind {
        case "LBRACE": "{"
        case "RBRACE": "}"
        case "LBRACKET": "["
        case "RBRACKET": "]"
        case "DIRECTED_EDGE": "->"
        case "UNDIRECTED_EDGE": "--"
        default: kind.lowercased()
        }
    }
}
