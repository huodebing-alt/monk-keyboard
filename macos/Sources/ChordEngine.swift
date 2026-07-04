import Foundation

/// A group of letters pressed "together" (within the chord window).
/// Order inside a group is unreliable (keyboard rollover), order across
/// groups is reliable.
struct ChordGroup {
    var letters: [Character]
}

struct Candidate {
    let word: String
    let score: Double
    /// score minus the arrival-order bonuses — what the letter *set* alone
    /// says. For chorded input this is the order-noise-free evidence.
    let orderFreeScore: Double
}

/// The Monk inference engine: given chord groups and context, rank the
/// words of the active dictionaries.
///
/// score(w) = log2 freq(w)
///          + exact-match bonus        (buffer spells w exactly)
///          + last-letter bonus        (chord ends on w's final letter)
///          - extra-letter penalty     (letters of w not covered by chord)
///          + user-adaptation bonus    (user picked w for this chord before)
///
/// Arrival order remains a full-strength *ranking* signal (an onset-ordered
/// chord should win locally), but per the reliability model stated on
/// ChordGroup it is never allowed to silently decide a chorded commit:
/// chorded input widens the ambiguity margin and enlarges the candidate
/// pool, so context (the on-device LM) gets the final say among words the
/// arrival order alone would have buried.
final class ChordEngine {

    struct Entry {
        let word: String     // display form (may carry accents)
        let folded: String   // accent-folded lowercase, used for matching
        let logFreq: Double
    }

    private var entries: [Entry] = []
    private var byFirst: [Character: [Int]] = [:]   // folded first letter -> entry indices
    private var wordSet: Set<String> = []
    private var userBoosts: [String: [String: Int]] = [:]  // chordKey -> word -> count
    private let userFile: URL

    static let exactBonus = 40.0
    static let lastLetterBonus = 3.0
    static let firstKeyBonus = 4.0      // word starts with the chronologically first key
    static let typedOrderBonus = 2.5    // arrival order already fits the word
    static let earlyWindowBonus = 2.0   // first chord letters cluster at the word start
    static let extraLetterPenalty = 0.22
    /// a chord is a deliberate compression of the word, so letters it leaves
    /// uncovered cost more than in sequential prefix entry
    static let chordedExtraLetterPenalty = 0.8
    static let userBoost = 6.0
    /// top1 - top2 margin below which we consider the chord ambiguous
    static let ambiguityMargin = 1.5
    /// wider margin for chorded input: intra-group arrival order is rollover
    /// noise, so order-derived gaps there shouldn't commit silently — near
    /// ties go to context (the on-device LM) or the bar instead
    static let chordedAmbiguityMargin = 3.0
    /// candidate pool for chorded input: deep enough that words the arrival
    /// order buried (e.g. "apple" from an unordered P,L,A,E) stay visible
    /// to the LM re-ranker
    static let chordedPoolLimit = 12
    /// pool seats reserved for the best *order-free* interpretations of a
    /// chord, so arrival-order bonuses can never crowd them out entirely
    static let orderFreeSeats = 6

    init(languages: [String], resourceDir: URL, supportDir: URL) {
        userFile = supportDir.appendingPathComponent("user.json")
        for lang in languages {
            let file = resourceDir.appendingPathComponent("\(lang).tsv")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count == 2, let freq = Double(parts[1]) else { continue }
                let word = String(parts[0])
                guard !wordSet.contains(word) else { continue }
                wordSet.insert(word)
                let folded = ChordEngine.fold(word)
                entries.append(Entry(word: word, folded: folded, logFreq: log2(freq + 1)))
            }
        }
        for (i, e) in entries.enumerated() {
            guard let f = e.folded.first else { continue }
            byFirst[f, default: []].append(i)
        }
        loadUserBoosts()
    }

    static func fold(_ s: String) -> String {
        return s.lowercased()
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en"))
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
    }

    func isWord(_ s: String) -> Bool { wordSet.contains(s.lowercased()) }

    /// Display form for a folded buffer, if a lexicon word folds to it
    /// ("doesnt" -> "doesn't"); nil when no word matches.
    func displayForm(folded: String) -> String? {
        guard let f = folded.first, let idxs = byFirst[f] else { return nil }
        for i in idxs where entries[i].folded == folded { return entries[i].word }
        return nil
    }

    /// Greedy subsequence match allowing free letter order inside a group.
    /// Returns false if any chord letter cannot be placed.
    static func matches(word: [Character], groups: [ChordGroup]) -> Bool {
        guard let firstGroup = groups.first, let w0 = word.first else { return false }
        guard firstGroup.letters.contains(w0) else { return false }
        var pos = 1
        var remaining = firstGroup.letters
        if let idx = remaining.firstIndex(of: w0) { remaining.remove(at: idx) }
        for gi in 0..<groups.count {
            if gi > 0 { remaining = groups[gi].letters }
            // consume group letters in whatever order matches earliest
            while !remaining.isEmpty {
                var bestLetter = -1
                var bestPos = Int.max
                for (li, ch) in remaining.enumerated() {
                    var p = pos
                    while p < word.count && word[p] != ch { p += 1 }
                    if p < word.count && p < bestPos { bestPos = p; bestLetter = li }
                }
                if bestLetter == -1 { return false }
                remaining.remove(at: bestLetter)
                pos = bestPos + 1
            }
        }
        return true
    }

    private func chordKey(_ groups: [ChordGroup]) -> String {
        groups.map { String($0.letters.sorted()) }.joined(separator: "|")
    }

    static func isPlainSubsequence(_ chord: [Character], of word: [Character]) -> Bool {
        var p = 0
        for ch in chord {
            while p < word.count && word[p] != ch { p += 1 }
            if p == word.count { return false }
            p += 1
        }
        return true
    }

    func candidates(groups: [ChordGroup], limit: Int = 9) -> [Candidate] {
        guard let firstGroup = groups.first, !firstGroup.letters.isEmpty else { return [] }
        let chorded = groups.contains { $0.letters.count > 1 }
        let chordLetters = groups.flatMap { $0.letters }  // chronological arrival order
        let flat = String(chordLetters)
        let firstKey = chordLetters[0]
        // early letters: only whole groups within the first three keys count —
        // a partial slice of a chorded group would be rollover noise
        var earlyLetters: [Character] = []
        for g in groups {
            if earlyLetters.count + g.letters.count > 3 { break }
            earlyLetters.append(contentsOf: g.letters)
            if earlyLetters.count >= 3 { break }
        }
        let key = chordKey(groups)
        let boosts = userBoosts[key] ?? [:]

        var results: [Candidate] = []
        // a chorded first group means any of its letters may be the word's first
        var indexSet: Set<Int> = []
        for f in firstGroup.letters {
            for i in byFirst[f] ?? [] { indexSet.insert(i) }
        }
        for i in indexSet {
            let e = entries[i]
            guard e.folded.count >= chordLetters.count else { continue }
            let wchars = Array(e.folded)
            guard ChordEngine.matches(word: wchars, groups: groups) else { continue }
            var score = e.logFreq
            // a chorded press never *means* the literal letter string
            if e.folded == flat && !chorded { score += ChordEngine.exactBonus }
            var orderBonus = 0.0
            if wchars[0] == firstKey { orderBonus += ChordEngine.firstKeyBonus }
            if ChordEngine.isPlainSubsequence(chordLetters, of: wchars) {
                orderBonus += ChordEngine.typedOrderBonus
            }
            let window = wchars.prefix(4)
            if earlyLetters.allSatisfy({ window.contains($0) }) {
                score += ChordEngine.earlyWindowBonus
            }
            // within a chorded final group any letter may be the word's ending —
            // unless that letter is the single key already serving as the onset
            if let lastGroup = groups.last?.letters, let wl = wchars.last {
                if lastGroup.count > 1 {
                    let consumedByOnset = groups.count == 1 && wl == wchars[0]
                    if lastGroup.contains(wl) && !consumedByOnset {
                        score += ChordEngine.lastLetterBonus
                    }
                } else if wl == lastGroup[0] {
                    score += ChordEngine.lastLetterBonus
                }
            }
            score -= (chorded ? ChordEngine.chordedExtraLetterPenalty
                              : ChordEngine.extraLetterPenalty)
                     * Double(wchars.count - chordLetters.count)
            if let n = boosts[e.word] { score += ChordEngine.userBoost * Double(min(n, 3)) }
            results.append(Candidate(word: e.word, score: score + orderBonus,
                                     orderFreeScore: score))
        }
        results.sort { $0.score > $1.score }
        guard chorded else { return Array(results.prefix(limit)) }
        // a chorded press carries no reliable intra-group order, so the best
        // order-free (letter-set) readings get guaranteed pool seats — the
        // LM re-ranker can only promote what the pool contains
        var picked: [Candidate] = []
        var seen = Set<String>()
        let byOrderFree = results.sorted { $0.orderFreeScore > $1.orderFreeScore }
        for c in byOrderFree.prefix(min(ChordEngine.orderFreeSeats, limit)) {
            picked.append(c)
            seen.insert(c.word)
        }
        for c in results {
            if picked.count >= limit { break }
            if seen.insert(c.word).inserted { picked.append(c) }
        }
        picked.sort { $0.score > $1.score }
        return picked
    }

    func isAmbiguous(_ cands: [Candidate], chorded: Bool = false) -> Bool {
        guard cands.count >= 2 else { return false }
        let gap = cands[0].score - cands[1].score
        guard chorded else { return gap < ChordEngine.ambiguityMargin }
        // for chorded input, also judge the gap with arrival-order bonuses
        // removed: a lead built on rollover order is not a real lead
        let of = cands.map { $0.orderFreeScore }.sorted(by: >)
        return min(gap, of[0] - of[1]) < ChordEngine.chordedAmbiguityMargin
    }

    // MARK: - user adaptation

    func learn(groups: [ChordGroup], chosen: String) {
        let key = chordKey(groups)
        userBoosts[key, default: [:]][chosen, default: 0] += 1
        saveUserBoosts()
    }

    private func loadUserBoosts() {
        guard let data = try? Data(contentsOf: userFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]]
        else { return }
        userBoosts = obj
    }

    private func saveUserBoosts() {
        let boosts = userBoosts
        let file = userFile
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONSerialization.data(withJSONObject: boosts) {
                try? data.write(to: file)
            }
        }
    }
}
