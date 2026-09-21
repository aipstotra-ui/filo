import Foundation
import Testing
@testable import FileOrganizer

/// End-to-end acceptance tests for M4 folder matching, run against the REAL
/// on-device stack: real NLEmbedding (`SentenceEmbeddingProvider`), real
/// extraction (`ExtractionEngine`), real profile builder, real matcher — no
/// mocks. They pin the product contract the 0.80 threshold was calibrated for:
///
///   • a file that belongs to a folder is suggested INTO that folder, and
///   • a file that belongs to NONE of the folders yields "No folder fits".
///
/// Calibration story (2026-07-19, macOS 26.5): NLEmbedding compresses cosine
/// scores into a high band. Measured on the representative set below, files
/// with a real home scored 0.84–0.94 (always ranking the right folder first)
/// while files belonging nowhere topped out at 0.78 — so the earlier 0.6
/// placeholder would force-match a stray file. The window (0.78, 0.84] holds
/// `FolderMatcher.matchThreshold` (0.80). These tests assert the *behavior* at
/// the shipped threshold, so they stay meaningful if scores drift slightly, and
/// break loudly if the threshold is moved back somewhere unsafe.
///
/// Set CALIB_OUT=<path> to also dump the full score matrix for re-tuning.
@Suite("Folder match acceptance", .serialized)
struct FolderMatchAcceptanceTests {

    /// A representative incoming file to classify. `expectedFolder == nil` means
    /// it belongs to none of the configured folders (→ `.noGoodMatch`).
    private struct Query {
        let label: String
        let filename: String
        let summary: String
        let snippet: String
        let expectedFolder: String?
    }

    /// A target folder: display name + its files. `content == nil` → a
    /// placeholder file with no extractable text (e.g. a screenshot with no OCR
    /// layer); `content != nil` → a `.txt` holding that text.
    private struct FolderSpec {
        let name: String
        let files: [(name: String, content: String?)]
    }

    private let folders: [FolderSpec] = [
        FolderSpec(name: "Screenshots", files: [
            ("Screenshot 2026-07-15 at 3.45.12 PM.png", nil),
            ("Screenshot 2026-07-16 at 9.02.41 AM.png", nil),
            ("Screenshot 2026-07-18 at 11.20.03 PM.png", nil),
        ]),
        FolderSpec(name: "Invoices", files: [
            ("Invoice-ACME-0441.txt", "INVOICE  ACME Corporation\nBill To: Jane Founder\nInvoice #0441   Date: 2026-06-01\nDescription: Consulting services\nSubtotal $1,100.00   Tax $140.00   Amount Due $1,240.00\nDue Date: 2026-07-01   Please remit payment to ACME Corporation."),
            ("Invoice-Globex-0212.txt", "Globex LLC  INVOICE 0212\nBilled To: Jane Founder\nQuantity 3  Unit Price $200  Line Total $600\nAmount Due: $600.00  Payment Terms Net 30  Thank you for your business."),
            ("Receipt-Adobe-2026-06.txt", "Adobe Receipt\nOrder Number AD-99231  Date 2026-06-14\nCreative Cloud Subscription  $59.99\nPayment Method Visa ending 4242  Total Charged $59.99"),
        ]),
        FolderSpec(name: "Recipes", files: [
            ("Chocolate Chip Cookies.txt", "Chocolate Chip Cookies\nIngredients: 2 cups flour, 1 cup butter, 1 cup sugar, 2 eggs, chocolate chips.\nInstructions: Cream butter and sugar. Add eggs. Fold in flour and chips. Bake at 375F for 11 minutes."),
            ("Thai Green Curry.txt", "Thai Green Curry\nIngredients: coconut milk, green curry paste, chicken, bamboo shoots, thai basil, fish sauce.\nSimmer curry paste in coconut milk, add chicken, cook until done. Serve with jasmine rice."),
            ("Sourdough Bread.txt", "Sourdough Bread\nIngredients: bread flour, water, active sourdough starter, salt.\nMix, autolyse, bulk ferment 4 hours with stretch and folds, shape, cold proof overnight, bake in a dutch oven."),
        ]),
        FolderSpec(name: "Tax Documents", files: [
            ("W2-2025.txt", "W-2 Wage and Tax Statement 2025\nEmployer: Startup Inc  Employee: Jane Founder\nBox 1 Wages $84,000.00  Box 2 Federal income tax withheld $14,200.00\nBox 3 Social security wages $84,000.00  Box 17 State income tax $4,100.00"),
            ("1099-INT-2025.txt", "Form 1099-INT Interest Income 2025\nPayer: Big Bank  Recipient: Jane Founder\nBox 1 Interest income $312.44  Box 4 Federal income tax withheld $0.00"),
            ("Property-Tax-2025.txt", "County Property Tax Statement 2025\nParcel 88-2201  Assessed Value $540,000\nAnnual Tax Due $6,480.00  First Installment Due 2025-11-01"),
        ]),
        FolderSpec(name: "Travel", files: [
            ("Flight Itinerary Tokyo.txt", "Flight Itinerary\nPassenger: Jane Founder  Confirmation ABC123\nSFO to HND  Departs 2026-09-02 11:20  Arrives 2026-09-03 15:40  Seat 24A  ANA Flight 7"),
            ("Hotel Booking Kyoto.txt", "Hotel Confirmation\nKyoto Garden Hotel  Check-in 2026-09-04  Check-out 2026-09-08\nRoom: Twin  Nights 4  Total 92,000 JPY  Confirmation KGH-5521"),
        ]),
    ]

    private let queries: [Query] = [
        // Positives — the founder's acceptance cases plus two more categories.
        Query(label: "SCREENSHOT",
              filename: "Screenshot 2026-07-19 at 10.14.55 AM.png",
              summary: "A screenshot of an application's settings window.",
              snippet: "Settings  General  Privacy  Notifications  Display  Sound  Keyboard  Trackpad",
              expectedFolder: "Screenshots"),
        Query(label: "INVOICE",
              filename: "Invoice-0447.pdf",
              summary: "An invoice from ACME Corporation with an amount due of $1,240.00.",
              snippet: "INVOICE  ACME Corporation  Bill To Jane Founder  Invoice #0447  Amount Due $1,240.00  Due Date 2026-08-01  Please remit payment.",
              expectedFolder: "Invoices"),
        Query(label: "RECIPE",
              filename: "Banana Bread.pdf",
              summary: "A recipe for banana walnut bread.",
              snippet: "Banana Bread  Ingredients 3 ripe bananas 2 cups flour 1 cup sugar 1/2 cup butter walnuts  Bake at 350F for 55 minutes.",
              expectedFolder: "Recipes"),
        Query(label: "TAX-FORM",
              filename: "W2-2026.pdf",
              summary: "A W-2 wage and tax statement for the 2026 tax year.",
              snippet: "W-2 Wage and Tax Statement 2026  Employer Startup Inc  Box 1 Wages $84,000  Box 2 Federal income tax withheld $14,200",
              expectedFolder: "Tax Documents"),

        // Negatives — belong to none of the five folders → "No folder fits".
        Query(label: "NEG-resume",
              filename: "Jane Founder Resume.pdf",
              summary: "A software engineer's professional resume and work history.",
              snippet: "Jane Founder  Software Engineer  Experience: Senior Engineer at Startup Inc 2022-2026. Skills: Swift, Python, distributed systems. Education: BS Computer Science.",
              expectedFolder: nil),
        Query(label: "NEG-song-lyrics",
              filename: "song draft.txt",
              summary: "Draft lyrics for an original acoustic song.",
              snippet: "Verse one  the morning light comes creeping through the pines  a quiet melody that lingers in my mind  chorus  we are the embers of a fading fire",
              expectedFolder: nil),
        Query(label: "NEG-source-code",
              filename: "server.py",
              summary: "A Python web server source file defining API route handlers.",
              snippet: "import flask  app = flask.Flask(__name__)  @app.route('/api/users')  def get_users():  return jsonify(db.query(User).all())  if __name__ == '__main__': app.run()",
              expectedFolder: nil),
        Query(label: "NEG-meeting-notes",
              filename: "standup 2026-07-19.txt",
              summary: "Notes from a team standup meeting with action items.",
              snippet: "Team Standup Notes  Attendees: Jane, Sam, Alex  Blockers: waiting on design review  Action items: Sam to file the migration ticket, Alex to update the changelog.",
              expectedFolder: nil),

        // NEAR-MISS negatives — semantically adjacent to a configured folder but
        // belonging to none of them. These probe the *true* stray ceiling (the
        // easy negatives above are semantically distant and understate it).
        Query(label: "NEG-bank-statement",  // financial, near Invoices + Tax Documents
              filename: "Chase Statement June 2026.pdf",
              summary: "A monthly bank account statement from Chase for June 2026.",
              snippet: "Chase Bank  Monthly Account Statement  Statement Period June 2026  Beginning Balance $3,905.12  Total Deposits $2,140.00  Total Withdrawals $1,835.44  Ending Balance $4,209.68  Account ending 8842",
              expectedFolder: nil),
        Query(label: "NEG-restaurant-menu",  // food words, near Recipes
              filename: "dinner menu.pdf",
              summary: "A restaurant's dinner menu with appetizers and entrees.",
              snippet: "Dinner Menu  Appetizers  Bruschetta 12  Calamari 15  Entrees  Grilled Salmon 28  Ribeye Steak 42  Wild Mushroom Risotto 24  Desserts  Tiramisu 11  Panna Cotta 10",
              expectedFolder: nil),
        Query(label: "NEG-utility-bill",  // has amounts + a sender, near Invoices
              filename: "PGE bill.pdf",
              summary: "A monthly electricity utility bill from the power company.",
              snippet: "Pacific Gas and Electric  Energy Statement  Service Period June 2026  Electricity used 620 kWh  Current Charges $148.32  Autopay scheduled for 2026-07-20  Account 5521-content-ish",
              expectedFolder: nil),
    ]

    @Test("A file's real home wins; a file that belongs nowhere yields no match")
    func acceptanceMatchesRealFoldersAndRejectsStrays() async throws {
        let embedder = SentenceEmbeddingProvider()

        // NLEmbedding sentence models ship with NaturalLanguage on macOS 26, so
        // this test HARD-REQUIRES one: with no embedder every query is empty and
        // every verdict collapses to .noGoodMatch, which would falsely "pass"
        // the negatives while gutting the positives. Fail explicitly (rather
        // than assert on sand) if the model is somehow absent — for this
        // macOS-26-only app its absence is a real problem, not a skip condition.
        guard embedder.embedding(for: "calibration probe sentence") != nil else {
            Issue.record("NLEmbedding sentence model unavailable — folder matching cannot work; this is a failure, not a skip.")
            return
        }

        let builder = FolderProfileBuilder(embedder: embedder, extractor: ExtractionEngine())

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m4-accept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // name → store-style ID, so a verdict's folderID maps back to a name.
        var candidates: [FolderMatchCandidate] = []
        var nameByID: [Int64: String] = [:]
        for (i, spec) in folders.enumerated() {
            let dir = root.appendingPathComponent(spec.name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in spec.files {
                let data = (file.content ?? "").data(using: .utf8) ?? Data()
                try data.write(to: dir.appendingPathComponent(file.name))
            }
            let profile = try await builder.buildProfile(for: dir)
            let id = Int64(i)
            candidates.append(FolderMatchCandidate(folderID: id, vectors: profile.vectors))
            nameByID[id] = spec.name
        }

        var matrix = "M4 folder-match score matrix (threshold \(FolderMatcher.matchThreshold))\n\n"

        for q in queries {
            // Build the query vectors exactly as PipelineModel does: the file's
            // content snippet, the AI summary, and the original filename, each
            // unit-normalized (the matcher excludes non-unit vectors).
            var query: [[Float]] = []
            for text in [q.snippet, q.summary, q.filename] {
                if let raw = embedder.embedding(for: text),
                   let unit = FolderMatcher.unitNormalized(raw) {
                    query.append(unit)
                }
            }

            let verdict = FolderMatcher.bestMatch(query: query, candidates: candidates)

            if let expected = q.expectedFolder {
                // Positive: must be suggested into its real home.
                if case let .match(folderID, score) = verdict {
                    #expect(nameByID[folderID] == expected,
                            "\(q.label): matched \(nameByID[folderID] ?? "?"), expected \(expected)")
                    #expect(score >= FolderMatcher.matchThreshold)
                } else {
                    Issue.record("\(q.label): expected a match to \(expected), got \(verdict)")
                }
            } else {
                // Negative: belongs nowhere → the honest fallback, never a match.
                #expect(verdict == .noGoodMatch,
                        "\(q.label): a stray file force-matched (\(verdict)) — threshold too low")
            }

            matrix += matrixRow(for: q, query: query, candidates: candidates, nameByID: nameByID)
        }

        if let outPath = ProcessInfo.processInfo.environment["CALIB_OUT"] {
            try? matrix.write(toFile: outPath, atomically: true, encoding: .utf8)
        }
    }

    /// One human-readable block: every folder's best score for this query,
    /// sorted high to low, plus the matcher's verdict. Diagnostics only.
    private func matrixRow(
        for q: Query,
        query: [[Float]],
        candidates: [FolderMatchCandidate],
        nameByID: [Int64: String]
    ) -> String {
        var scored: [(name: String, score: Float)] = []
        for cand in candidates {
            var best: Float = -2
            for qv in query {
                for pv in cand.vectors.map(\.values) where pv.count == qv.count {
                    best = max(best, FolderMatcher.cosine(qv, pv))
                }
            }
            scored.append((nameByID[cand.folderID] ?? "?", best))
        }
        scored.sort { $0.score > $1.score }
        let expect = q.expectedFolder ?? "— none —"
        var block = "\(q.label)  (expect \(expect))\n"
        for s in scored {
            block += String(format: "    %-16@ %.4f\n", s.name as NSString, s.score)
        }
        return block + "\n"
    }
}
