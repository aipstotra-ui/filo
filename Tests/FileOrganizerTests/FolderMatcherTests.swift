import Foundation
import Testing
@testable import FileOrganizer

/// Contract tests for FolderMatcher — the pure matching math (no I/O).
/// A wrong verdict here means a file gets suggested into the wrong folder,
/// so every boundary and exclusion rule is pinned exactly.
@Suite("FolderMatcher")
struct FolderMatcherTests {

    /// A unit vector whose dot product with [1, 0] is exactly `score`
    /// (first component times 1, second times 0 — exact in Float).
    private func unitVector(scoring score: Float) -> [Float] {
        [score, (max(0, 1 - score * score)).squareRoot()]
    }

    private func candidate(
        id: Int64, kind: FolderVectorKind = .name, _ vectors: [[Float]]
    ) -> FolderMatchCandidate {
        FolderMatchCandidate(
            folderID: id,
            vectors: vectors.map { FolderVector(kind: kind, values: $0) }
        )
    }

    // MARK: - Cosine math

    @Test("Cosine of identical normalized vectors is 1.0")
    func cosineOfIdenticalVectorsIsOne() {
        #expect(FolderMatcher.cosine([1, 0, 0], [1, 0, 0]) == 1.0)
        let similarity = FolderMatcher.cosine([0.6, 0.8], [0.6, 0.8])
        #expect(abs(similarity - 1.0) < 1e-6)
    }

    @Test("Cosine of orthogonal vectors is 0")
    func cosineOfOrthogonalVectorsIsZero() {
        #expect(FolderMatcher.cosine([1, 0], [0, 1]) == 0)
        #expect(FolderMatcher.cosine([0, 1, 0], [0, 0, 1]) == 0)
    }

    // MARK: - Tuning constants (founder-pinned semantics)

    @Test("Threshold is a real cosine bar and the tie margin is 0.02")
    func tuningConstantsAreSane() {
        #expect(FolderMatcher.matchThreshold > 0)
        #expect(
            FolderMatcher.matchThreshold <= 0.9,
            "several matcher tests use scores of 0.99+; the threshold must stay below them"
        )
        #expect(FolderMatcher.tieMargin == 0.02)
    }

    // MARK: - Threshold boundary

    @Test("Score exactly at the threshold is a match")
    func scoreExactlyAtThresholdMatches() {
        let threshold = FolderMatcher.matchThreshold
        let folders = [candidate(id: 1, [unitVector(scoring: threshold)])]
        let verdict = FolderMatcher.bestMatch(query: [[1, 0]], candidates: folders)
        #expect(verdict == .match(folderID: 1, score: threshold))
    }

    @Test("Score just below the threshold is noGoodMatch")
    func scoreJustBelowThresholdIsNoGoodMatch() {
        let justBelow = FolderMatcher.matchThreshold.nextDown
        let folders = [candidate(id: 1, [unitVector(scoring: justBelow)])]
        let verdict = FolderMatcher.bestMatch(query: [[1, 0]], candidates: folders)
        #expect(verdict == .noGoodMatch)
    }

    // MARK: - Empty inputs

    @Test("No folders configured is its own verdict, even with an empty query")
    func noFoldersIsItsOwnVerdict() {
        #expect(
            FolderMatcher.bestMatch(query: [[1, 0]], candidates: []) == .noFoldersConfigured
        )
        #expect(
            FolderMatcher.bestMatch(query: [], candidates: []) == .noFoldersConfigured,
            "no-folders takes precedence: the user's fix is to configure folders"
        )
    }

    @Test("A query with zero vectors is noGoodMatch, never a fabricated match")
    func emptyQueryIsNoGoodMatch() {
        let folders = [candidate(id: 1, [[1, 0]])]
        #expect(FolderMatcher.bestMatch(query: [], candidates: folders) == .noGoodMatch)
    }

    // MARK: - Dimension mismatches

    @Test("A folder whose vectors all mismatch the query dimension is excluded")
    func allFoldersDimensionMismatchedIsNoGoodMatch() {
        let folders = [candidate(id: 1, [[1, 0]])] // 2-dim vs 3-dim query
        let verdict = FolderMatcher.bestMatch(query: [[1, 0, 0]], candidates: folders)
        #expect(verdict == .noGoodMatch, "must exclude, never crash or fabricate")
    }

    @Test("A mixed-dimension folder still matches through its compatible vector")
    func mixedDimensionFolderUsesCompatibleVector() {
        let folders = [candidate(id: 2, [[0, 1], [1, 0, 0]])]
        let verdict = FolderMatcher.bestMatch(query: [[1, 0, 0]], candidates: folders)
        #expect(verdict == .match(folderID: 2, score: 1.0))
    }

    // MARK: - Max over all query × profile pairs

    @Test("Score is the max over every query-vector × profile-vector pair")
    func scoreIsMaxOverAllPairs() {
        // Only the second query vector aligns with the folder.
        let folders = [candidate(id: 5, [[0, 1]])]
        let verdict = FolderMatcher.bestMatch(query: [[1, 0], [0, 1]], candidates: folders)
        #expect(verdict == .match(folderID: 5, score: 1.0))
    }

    // MARK: - Tie-breaking (deterministic)

    @Test("Tie within the margin goes to the earliest-added folder")
    func tieWithinMarginGoesToEarliestAdded() {
        // Candidate order is added order; IDs deliberately out of numeric
        // order so the pin is on position, not on the smaller ID.
        let folders = [
            candidate(id: 7, [unitVector(scoring: 0.99)]),
            candidate(id: 3, [unitVector(scoring: 1.0)]),
        ]
        let verdict = FolderMatcher.bestMatch(query: [[1, 0]], candidates: folders)
        #expect(
            verdict == .match(folderID: 7, score: 0.99),
            "0.99 vs 1.0 is within the 0.02 margin: earliest-added wins, at its own score"
        )
    }

    @Test("A clear winner beats an earlier-added folder outside the margin")
    func clearWinnerBeatsEarlierFolder() {
        let folders = [
            candidate(id: 1, [unitVector(scoring: 0.7)]),
            candidate(id: 2, [unitVector(scoring: 1.0)]),
        ]
        let verdict = FolderMatcher.bestMatch(query: [[1, 0]], candidates: folders)
        #expect(verdict == .match(folderID: 2, score: 1.0))
    }

    // MARK: - Non-normalized vectors are rejected (pinned choice)

    @Test("A non-normalized profile vector is excluded, never scored")
    func nonNormalizedProfileVectorIsExcluded() {
        // Naive dot product would score 3.0 — a fabricated super-match.
        let folders = [candidate(id: 1, [[3, 0]])]
        let verdict = FolderMatcher.bestMatch(query: [[1, 0]], candidates: folders)
        #expect(verdict == .noGoodMatch)
    }

    @Test("A non-normalized query vector is excluded, never scored")
    func nonNormalizedQueryVectorIsExcluded() {
        let folders = [candidate(id: 1, [[1, 0]])]
        let verdict = FolderMatcher.bestMatch(query: [[2, 0]], candidates: folders)
        #expect(verdict == .noGoodMatch)
    }

    @Test("A zero vector is excluded without crashing, and good vectors still count")
    func zeroVectorExcludedGoodVectorStillCounts() {
        let allZero = [candidate(id: 1, [[0, 0]])]
        #expect(FolderMatcher.bestMatch(query: [[1, 0]], candidates: allZero) == .noGoodMatch)

        // Same folder carrying one bad and one good vector: the bad one is
        // dropped, the good one still matches.
        let mixed = [candidate(id: 4, [[3, 0], [0, 1]])]
        let verdict = FolderMatcher.bestMatch(query: [[0, 1]], candidates: mixed)
        #expect(verdict == .match(folderID: 4, score: 1.0))
    }
}
