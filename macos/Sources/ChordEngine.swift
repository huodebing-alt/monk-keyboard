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
}

/// The Comp inference engine: given chord groups and context, rank the
/// words of the active dictionaries.
///
/// score(w) = log2 freq(w)
///          + exact-match bonus        (buffer spells w exactly)
///          + last-letter bonus        (chord ends on w's final letter)
///          - extra-letter penalty     (letters of w not covered by chord)
///          + user-adaptation bonus    (user picked w for this chord before)
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
    static let userBoost = 6.0
    /// top1 - top2 margin below which we consider the chord ambiguous
    static let ambiguityMargin = 1.5

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
    }

    func isWord(_ s: String) -> Bool { wordSet.contains(s.lowercased()) }

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
        let lastLetter = chordLetters.last
        let earlyLetters = chordLetters.prefix(min(3, chordLetters.count))
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
            if wchars[0] == firstKey { score += ChordEngine.firstKeyBonus }
            if ChordEngine.isPlainSubsequence(chordLetters, of: wchars) {
                score += ChordEngine.typedOrderBonus
            }
            let window = wchars.prefix(4)
            if earlyLetters.allSatisfy({ window.contains($0) }) {
                score += ChordEngine.earlyWindowBonus
            }
            if let last = lastLetter, wchars.last == last { score += ChordEngine.lastLetterBonus }
            score -= ChordEngine.extraLetterPenalty * Double(wchars.count - chordLetters.count)
            if let n = boosts[e.word] { score += ChordEngine.userBoost * Double(min(n, 3)) }
            results.append(Candidate(word: e.word, score: score))
        }
        results.sort { $0.score > $1.score }
        return Array(results.prefix(limit))
    }

    func isAmbiguous(_ cands: [Candidate]) -> Bool {
        guard cands.count >= 2 else { return false }
        return cands[0].score - cands[1].score < ChordEngine.ambiguityMargin
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
