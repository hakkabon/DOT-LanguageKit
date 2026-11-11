import DOTLanguage
import Foundation
import IncrementalParsing
import Testing

@Suite("DOT language provider")
struct DOTProviderTests {
    @Test func analyzesDirectedGraphAndReusesLexing() async throws {
        let session = DOTProvider().makeToolingSession()
        let first = SourceSnapshot(
            text: "digraph G { a -> b; }", revision: .init(1))
        let clean = try await session.analyze(first)
        #expect(clean.diagnostics.isEmpty)
        #expect(clean.tokens.contains { $0.classification == "keyword" })

        let location = (first.text as NSString).range(of: "b").location
        let change = try SourceEdit(
            baseRevision: first.revision,
            range: .init(location: location, length: 1), replacement: "node")
            .applying(to: first)
        let changed = try await session.analyze(change.after, change: change)
        #expect(changed.evidence(for: "lexing")?.strategy == .incremental)
        #expect(changed.diagnostics.isEmpty)
        #expect(!(try await session.semanticTokens()).data.isEmpty)
    }

    @Test func recoversHeaderDelimiterAndEdgeKind() async throws {
        let result = try await DOTProvider().makeSession().analyze(.init(
            text: "graph G { a -> b;", revision: .init(1)))
        #expect(result.diagnostics.contains { $0.expected.contains("--") })
        #expect(result.diagnostics.contains { $0.expected.contains("}") })
        #expect(!result.recoveryEdits.isEmpty)
    }
}
