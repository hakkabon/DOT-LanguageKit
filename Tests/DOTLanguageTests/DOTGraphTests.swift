import DOTLanguage
import Foundation
import IncrementalParsing
import Testing

@Test func projectsLabeledGraphAndNodeSourceRanges() async throws {
    let text = #"""
        digraph G {
            graph [rankdir=LR]
            edge [label="default"]
            "🟦" -> next -> end [label="follow"]
            next [label="Next\nstep"]
            end -> end
        }
        """#
    let session = DOTProviderSession()
    let result = try await session.analyzeGraph(.init(text: text, revision: .init(1)))
    guard case .graph(let graph) = result else {
        Issue.record("Expected a graph, got \(result)")
        return
    }
    #expect(graph.directed && graph.leftToRight)
    #expect(graph.nodes.map(\.id) == ["🟦", "next", "end"])
    #expect(graph.nodes[1].label == "Next\nstep")
    let range = graph.nodes[1].range
    #expect(range.location == (text as NSString).range(of: "next [").location)
    #expect(range.length == 4)
    #expect(graph.edges.map(\.label) == ["follow", "follow", "default"])
}

@Test func projectsStrictUndirectedEdgesAndRejectsBrokenStatements() async throws {
    let session = DOTProviderSession()
    let valid = SourceSnapshot(text: #"strict graph { a -- b; b -- a [label="link"] }"#, revision: .init(1))
    guard case .graph(let graph) = try await session.analyzeGraph(valid) else {
        Issue.record("Expected an undirected graph")
        return
    }
    #expect(!graph.directed)
    #expect(graph.edges.count == 1)
    #expect(graph.edges.first?.label == "link")

    let broken = SourceSnapshot(text: "graph { a -- }", revision: .init(2))
    #expect(try await session.analyzeGraph(broken) == .invalid)
    let analysis = try await session.analyze(broken, change: nil)
    #expect(analysis.diagnostics.contains { $0.message == "Expected a DOT identifier" })

    let subgraph = SourceSnapshot(text: "graph { subgraph cluster { a } }", revision: .init(3))
    guard case .unsupported = try await session.analyzeGraph(subgraph) else {
        Issue.record("Expected an unsupported preview")
        return
    }
    #expect(try await session.analyze(subgraph, change: nil).diagnostics.isEmpty)
}
