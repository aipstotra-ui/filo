import Foundation

/// One indexed folder as the matcher sees it: the store's row ID plus its
/// profile vectors. Candidates must be passed in added order (earliest first
/// — `FolderIndexStore.allProfiles()` returns them that way); ties within
/// `FolderMatcher.tieMargin` resolve to the earliest candidate in the array.
struct FolderMatchCandidate: Sendable, Equatable {
    let folderID: Int64
    let vectors: [FolderVector]
}

/// The matcher's verdict for one file. Modeled as an enum so "no folders set
/// up yet" and "folders exist but none fit" stay distinct in the UI.
enum MatchVerdict: Sendable, Equatable {
    case match(folderID: Int64, score: Float)
    case noGoodMatch
    case noFoldersConfigured
}

/// Pure matching math — no I/O, no state. Score = max dot product (cosine on
/// unit vectors) over every query-vector × profile-vector pair with matching
/// dimensions. Vectors that are not unit length (beyond a small tolerance)
/// or whose dimension matches nothing are EXCLUDED from scoring — a bad
/// vector must never fabricate a match (pinned in FolderMatcherTests).
enum FolderMatcher {

    /// Minimum score for a `.match` verdict; score >= threshold matches.
    ///
    /// PROVISIONAL, calibrated 2026-07-19 against real NLEmbedding on macOS 26.5
    /// using a synthetic representative set (FolderMatchAcceptanceTests) with
    /// stand-in AI summaries — NOT yet against the founder's real folders with
    /// real on-device AI summaries, which stays the sign-off gate (docs/
    /// milestones.md M4). NLEmbedding compresses cosine into a high band, so the
    /// earlier 0.6 placeholder force-matched strays. Measured on that set:
    /// real-home files score 0.84–0.94; strays (incl. near-misses — a bank
    /// statement vs Tax/Invoices) top out at 0.78. Window (0.78, 0.84]; 0.80
    /// leans slightly to recall. The near-miss margin is thin (~0.02), tolerable
    /// only because a match merely *suggests* a destination (M4 never moves a
    /// file) and "No folder fits" is the honest fallback. Re-tune with
    /// CALIB_OUT=… swift test --filter FolderMatchAcceptanceTests.
    static let matchThreshold: Float = 0.80

    /// Candidates scoring within this margin of the top score are a tie;
    /// the earliest-added candidate wins. Founder-pinned at 0.02.
    static let tieMargin: Float = 0.02

    /// How far a squared length may drift from 1 before a vector is rejected
    /// as non-normalized. Covers Float rounding, nothing more.
    private static let unitLengthTolerance: Float = 1e-3

    /// Cosine similarity of two same-dimension vectors (dot product when both
    /// are unit length). Same-dimension is the caller's responsibility here;
    /// `bestMatch` filters dimensions before calling.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// The best folder for a query (each query vector unit length, e.g. the
    /// file's content embedding and its filename embedding).
    static func bestMatch(
        query: [[Float]],
        candidates: [FolderMatchCandidate]
    ) -> MatchVerdict {
        guard !candidates.isEmpty else { return .noFoldersConfigured }

        let usableQuery = query.filter(isUnitLength)
        guard !usableQuery.isEmpty else { return .noGoodMatch }

        // Score every candidate that has at least one usable, dimension-
        // compatible vector; candidates with none simply never score.
        var scored: [(folderID: Int64, score: Float)] = []
        for candidate in candidates {
            let usableVectors = candidate.vectors
                .map(\.values)
                .filter(isUnitLength)
            var best: Float?
            for queryVector in usableQuery {
                for profileVector in usableVectors
                where profileVector.count == queryVector.count {
                    let similarity = cosine(queryVector, profileVector)
                    best = max(best ?? similarity, similarity)
                }
            }
            if let best {
                scored.append((candidate.folderID, best))
            }
        }

        guard let topScore = scored.map(\.score).max(),
              topScore >= matchThreshold else {
            return .noGoodMatch
        }

        // Ties go to the earliest-added candidate: the first one within the
        // margin of the top score (and above the bar itself) wins, reported
        // at its own score.
        for (folderID, score) in scored
        where score >= topScore - tieMargin && score >= matchThreshold {
            return .match(folderID: folderID, score: score)
        }

        // Unreachable: the top scorer itself always satisfies the loop.
        return .noGoodMatch
    }

    /// True when the vector is unit length within `unitLengthTolerance`.
    /// Zero and empty vectors are not unit length, so they are excluded too.
    private static func isUnitLength(_ vector: [Float]) -> Bool {
        abs(cosine(vector, vector) - 1) <= unitLengthTolerance
    }

    /// Normalizes a raw embedding to unit length — done once by producers
    /// (profile build, query build) because `bestMatch` excludes rather than
    /// repairs non-unit vectors. nil for zero, empty, or non-finite input.
    static func unitNormalized(_ vector: [Float]) -> [Float]? {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0, length.isFinite else { return nil }
        return vector.map { $0 / length }
    }
}
