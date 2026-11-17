import Foundation
import IncrementalParsing
import Lexer

public struct DOTGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let range: SourceRange
    }

    public struct Edge: Sendable, Equatable {
        public let from: String
        public let to: String
        public let label: String?
    }

    public let directed: Bool
    public let leftToRight: Bool
    public let nodes: [Node]
    public let edges: [Edge]
}

public enum DOTGraphPreview: Sendable, Equatable {
    case graph(DOTGraph)
    case invalid
    case unsupported(String)
}

struct DOTGraphParser {
    private struct EdgeKey: Hashable {
        let from: String
        let to: String
    }

    enum Failure: Error {
        case syntax(String, SourceRange)
        case unsupported(String)
    }

    let tokens: [GrammarLexicalToken]
    let endOffset: Int
    private var index = 0
    private var nodes: [DOTGraph.Node] = []
    private var nodeIndices: [String: Int] = [:]
    private var explicitlyDeclared: Set<String> = []
    private var edges: [DOTGraph.Edge] = []
    private var edgeIndices: [EdgeKey: Int] = [:]
    private var defaultNodeLabel: String?
    private var defaultEdgeLabel: String?
    private var leftToRight = false

    init(tokens: [GrammarLexicalToken], endOffset: Int) {
        self.tokens = tokens
        self.endOffset = endOffset
    }

    mutating func parse() throws -> DOTGraph {
        let strict = take("STRICT")
        let directed = take("DIGRAPH")
        if !directed { try expect("GRAPH", "Expected 'graph' or 'digraph'") }
        if kind != "LBRACE" { _ = try identifier() }
        try expect("LBRACE", "Expected '{' before graph statements")

        while kind != "RBRACE" && kind != nil {
            if take("SEMICOLON") { continue }
            if kind == "SUBGRAPH" || kind == "LBRACE" {
                throw Failure.unsupported("Subgraphs and clusters are outside the DOT preview subset.")
            }
            if let kind, ["NODE", "EDGE", "GRAPH"].contains(kind),
               index + 1 < tokens.count, tokens[index + 1].kind == "LBRACKET" {
                index += 1
                let values = try attributes()
                switch kind {
                case "NODE": defaultNodeLabel = values["label"] ?? defaultNodeLabel
                case "EDGE": defaultEdgeLabel = values["label"] ?? defaultEdgeLabel
                default: setDirection(values["rankdir"])
                }
                continue
            }

            let first = try identifier()
            if take("EQUAL") {
                let value = try identifier()
                if first.id == "rankdir" { setDirection(value.id) }
                continue
            }
            let op = directed ? "DIRECTED_EDGE" : "UNDIRECTED_EDGE"
            if take(op) {
                var chain = [first]
                repeat {
                    if kind == "SUBGRAPH" || kind == "LBRACE" {
                        throw Failure.unsupported("Subgraph edge endpoints are outside the DOT preview subset.")
                    }
                    chain.append(try identifier())
                } while take(op)
                let label = try attributes()["label"]
                for node in chain { record(node, label: nil, declaration: false) }
                for (from, to) in zip(chain, chain.dropFirst()) {
                    let key = directed || from.id <= to.id
                        ? EdgeKey(from: from.id, to: to.id) : EdgeKey(from: to.id, to: from.id)
                    if strict, let existing = edgeIndices[key] {
                        if let label {
                            let edge = edges[existing]
                            edges[existing] = .init(from: edge.from, to: edge.to, label: label)
                        }
                    } else {
                        if strict { edgeIndices[key] = edges.count }
                        edges.append(.init(from: from.id, to: to.id, label: label ?? defaultEdgeLabel))
                    }
                }
            } else {
                let label = try attributes()["label"]
                record(first, label: label, declaration: true)
            }
        }
        try expect("RBRACE", "Expected '}' after graph statements")
        if kind != nil { throw syntax("Unexpected text after the graph") }
        return DOTGraph(directed: directed, leftToRight: leftToRight, nodes: nodes, edges: edges)
    }

    private mutating func record(_ node: (id: String, range: SourceRange),
                                 label: String?, declaration: Bool) {
        let isFirstDeclaration = declaration && explicitlyDeclared.insert(node.id).inserted
        if let index = nodeIndices[node.id] {
            let old = nodes[index]
            nodes[index] = .init(id: node.id, label: label?.replacingDOTNodeName(with: node.id) ?? old.label,
                                 range: isFirstDeclaration ? node.range : old.range)
        } else {
            nodeIndices[node.id] = nodes.count
            let label = (label ?? defaultNodeLabel)?.replacingDOTNodeName(with: node.id) ?? node.id
            nodes.append(.init(id: node.id, label: label, range: node.range))
        }
    }

    private mutating func attributes() throws -> [String: String] {
        var values: [String: String] = [:]
        while take("LBRACKET") {
            while kind != "RBRACKET" && kind != nil {
                if take("SEMICOLON") || take("COMMA") { continue }
                let key = try identifier().id
                try expect("EQUAL", "Expected '=' after attribute name")
                if kind == "HTML", key != "label" {
                    index += 1
                    continue
                }
                values[key] = try identifier().id
            }
            try expect("RBRACKET", "Expected ']' after attributes")
        }
        return values
    }

    private mutating func setDirection(_ direction: String?) {
        if let direction { leftToRight = direction == "LR" }
    }

    private mutating func identifier() throws -> (id: String, range: SourceRange) {
        if kind == "HTML" {
            throw Failure.unsupported("HTML-like IDs and labels are outside the DOT preview subset.")
        }
        guard let kind, ["ID", "NUMBER", "STRING", "NODE", "EDGE", "GRAPH"].contains(kind) else {
            throw syntax("Expected a DOT identifier")
        }
        let token = tokens[index]
        index += 1
        if self.kind == "PLUS", kind == "STRING" {
            throw Failure.unsupported("Concatenated strings are outside the DOT preview subset.")
        }
        if self.kind == "COLON" {
            throw Failure.unsupported("Ports are outside the DOT preview subset.")
        }
        let value = kind == "STRING" ? unquote(token.lexeme) : token.lexeme
        return (value, .init(token.range.lowerBound, token.range.upperBound))
    }

    private func unquote(_ spelling: String) -> String {
        var characters = spelling.dropFirst().dropLast().makeIterator()
        var result = ""
        while let character = characters.next() {
            if character == "\\", let escaped = characters.next() {
                switch escaped {
                case "\"": result.append(escaped)
                case "\\": result.append(escaped)
                case "n", "l", "r": result.append("\n")
                case "\n", "\r\n": break
                default: result.append(character); result.append(escaped)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    private var kind: String? { index < tokens.count ? tokens[index].kind : nil }

    private mutating func take(_ kind: String) -> Bool {
        guard self.kind == kind else { return false }
        index += 1
        return true
    }

    private mutating func expect(_ kind: String, _ message: String) throws {
        guard take(kind) else { throw syntax(message) }
    }

    private func syntax(_ message: String) -> Failure {
        let range = index < tokens.count ? tokens[index].range : endOffset..<endOffset
        return .syntax(message, .init(range.lowerBound, range.upperBound))
    }
}

private extension String {
    func replacingDOTNodeName(with id: String) -> String {
        replacingOccurrences(of: "\\N", with: id)
    }
}
