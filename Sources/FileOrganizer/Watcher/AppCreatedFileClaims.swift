import Foundation

/// Names the app is about to create in the watched folder, so its own output is
/// not mistaken for a new download.
///
/// The watcher diffs the folder by NAME, so a rename-in-place — or an undo
/// restoring a file back into Downloads — otherwise looks exactly like a brand
/// new download and gets a suggestion made for it (risk #8).
///
/// Three things make this a separate type rather than a dictionary on the
/// watcher (M7):
///
/// 1. **It is genuinely concurrent.** The mover announces candidates from a
///    detached task, while the watcher reads them on the main queue. A claim
///    *must* be registered before the write is attempted, so it cannot simply
///    hop to the main queue first — by the time it arrived, the file could
///    already be on disk. The package is Swift 5 language mode, so the compiler
///    will not diagnose the race; the lock is the whole point of this type.
/// 2. **Claims are scoped to one directory.** The mover moves files into folders
///    all over the disk; only the watched folder's names can ever be confused
///    with a download, and claiming names elsewhere would be dead state.
/// 3. **Claims are spent, and released as a group.** The mover announces every
///    rung of its collision ladder but uses at most one. An unused rung left
///    lying around is not harmless: if the user downloads a file with that exact
///    name shortly afterwards, it would be adopted as ours and **never
///    announced** — no popup, no menu row, ever. So a claim is consumed the
///    first time it matches, and the rungs a finished move did not use are
///    dropped the moment it settles rather than aging out minutes later.
final class AppCreatedFileClaims: @unchecked Sendable {

    private struct Claim {
        /// EVERY move that has announced this name, not just the latest.
        ///
        /// A `Set`, because two accepts run concurrently whenever the user
        /// accepts a second file while the first is still moving — which
        /// founder decision 5 makes ordinary, since a move outlives its panel.
        /// Storing one owner made the second claim overwrite the first, so when
        /// the *second* move settled it released a name the *first* move's real
        /// file depended on, and the watcher then announced the file this app
        /// had just written as a brand-new download (F9 / risk #8).
        var groups: Set<UUID>
        /// When the most recent claimant announced it, so the backstop expiry
        /// tracks the newest claim rather than the oldest.
        var claimedAt: Date
    }

    /// Backstop for a move that never reports settling at all (a crash between
    /// claiming and finishing). Generous: a cross-volume move is a copy, and a
    /// large file can take minutes. Normal operation never reaches it, because
    /// `releaseUnused` retires claims as soon as the move is done.
    private let lifetime: TimeInterval

    /// Canonical path of the only directory whose names are worth claiming.
    private let directoryPath: String

    private let lock = NSLock()
    /// filename -> claim. Guarded by `lock`; never touched outside it.
    private var claims: [String: Claim] = [:]

    init(watching directory: URL, lifetime: TimeInterval = 300) {
        self.directoryPath = FileMover.canonicalDirectoryPath(directory)
        self.lifetime = lifetime
    }

    /// Registers a name the app is about to write, if it lands in the watched
    /// folder. Call it **before** attempting the write, for every candidate that
    /// might be used.
    ///
    /// Safe to call from any thread — this is the seam the mover calls from a
    /// detached task.
    func claim(_ url: URL, group: UUID, now: Date = Date()) {
        guard FileMover.canonicalDirectoryPath(url.deletingLastPathComponent())
                == directoryPath else {
            return  // another folder entirely; the watcher will never see it
        }
        lock.lock()
        defer { lock.unlock() }
        let name = url.lastPathComponent
        var claim = claims[name] ?? Claim(groups: [], claimedAt: now)
        claim.groups.insert(group)
        claim.claimedAt = now
        claims[name] = claim
    }

    /// The move owning `group` has finished. Drops that move's interest in every
    /// name it announced except `used` — the name its file actually landed
    /// under, which must survive until the watcher has seen it.
    ///
    /// A name only leaves the box once the LAST interested move has let it go.
    /// One move settling can no longer retire a name another move is still
    /// relying on (F9).
    ///
    /// Pass `used: nil` for a move that failed: it created nothing, so every one
    /// of its claims is dead weight that could shadow a real download.
    func releaseUnused(group: UUID, keeping used: URL?) {
        let keptName = used.map { $0.lastPathComponent }
        lock.lock()
        defer { lock.unlock() }
        for (name, var claim) in claims where claim.groups.contains(group) {
            guard name != keptName else { continue }
            claim.groups.remove(group)
            if claim.groups.isEmpty {
                claims.removeValue(forKey: name)
            } else {
                claims[name] = claim
            }
        }
    }

    /// Called by the watcher on every folder scan. Returns the claimed names
    /// that are now on disk — which the watcher adopts as ordinary known files
    /// — and **removes them**, because a claim is spent the first time it is
    /// honoured. Also drops claims that have aged past `lifetime`.
    ///
    /// A claim is never dropped merely because its file has not appeared yet:
    /// that is the normal state of a slow move, and dropping it there would
    /// re-announce the app's own output.
    func consumeAppeared(presentNames: Set<String>, now: Date = Date()) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        var appeared: Set<String> = []
        var surviving: [String: Claim] = [:]
        for (name, claim) in claims {
            if presentNames.contains(name) {
                // Presence beats age: adopting late is right, because announcing
                // our own output as a new download is the bug being prevented.
                appeared.insert(name)
            } else if now.timeIntervalSince(claim.claimedAt) < lifetime {
                surviving[name] = claim
            }
        }
        claims = surviving
        return appeared
    }

    /// Claim count, for tests and diagnostics only.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return claims.count
    }
}
