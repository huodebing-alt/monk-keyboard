/* Comp chord-inference engine — JavaScript port of macos/Sources/ChordEngine.swift.
 * Keep the scoring constants in sync with the Swift implementation. */

const SCORE = {
  exactBonus: 40.0,
  lastLetterBonus: 3.0,
  firstKeyBonus: 4.0,
  typedOrderBonus: 2.5,
  earlyWindowBonus: 2.0,
  extraLetterPenalty: 0.22,
  userBoost: 6.0,
  ambiguityMargin: 1.5,
};

function foldAccents(s) {
  return s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
}

class ChordEngine {
  constructor() {
    this.entries = [];        // {word, folded, logFreq}
    this.byFirst = new Map(); // first letter -> entry indices
    this.wordSet = new Set();
    this.userBoosts = new Map(); // chordKey -> Map(word -> count)
  }

  load(pairs) { // pairs: [[word, count], ...]
    this.entries = [];
    this.byFirst = new Map();
    this.wordSet = new Set();
    for (const [word, count] of pairs) {
      if (this.wordSet.has(word)) continue;
      this.wordSet.add(word);
      const folded = foldAccents(word);
      const idx = this.entries.length;
      this.entries.push({ word, folded, logFreq: Math.log2(count + 1) });
      const f = folded[0];
      if (!this.byFirst.has(f)) this.byFirst.set(f, []);
      this.byFirst.get(f).push(idx);
    }
  }

  isWord(s) { return this.wordSet.has(s.toLowerCase()); }

  /* groups: [[chars...], ...] — arrival order inside each group,
   * reliable order across groups. */
  static matches(word, groups) {
    if (!groups.length || !word.length) return false;
    const first = groups[0];
    if (!first.includes(word[0])) return false;
    let pos = 1;
    let remaining = first.slice();
    remaining.splice(remaining.indexOf(word[0]), 1);
    for (let gi = 0; gi < groups.length; gi++) {
      if (gi > 0) remaining = groups[gi].slice();
      while (remaining.length) {
        let bestLetter = -1, bestPos = Infinity;
        for (let li = 0; li < remaining.length; li++) {
          let p = pos;
          while (p < word.length && word[p] !== remaining[li]) p++;
          if (p < word.length && p < bestPos) { bestPos = p; bestLetter = li; }
        }
        if (bestLetter === -1) return false;
        remaining.splice(bestLetter, 1);
        pos = bestPos + 1;
      }
    }
    return true;
  }

  static isPlainSubsequence(chord, word) {
    let p = 0;
    for (const ch of chord) {
      while (p < word.length && word[p] !== ch) p++;
      if (p === word.length) return false;
      p++;
    }
    return true;
  }

  chordKey(groups) {
    return groups.map((g) => g.slice().sort().join("")).join("|");
  }

  candidates(groups, limit = 9) {
    if (!groups.length || !groups[0].length) return [];
    const chorded = groups.some((g) => g.length > 1);
    const chordLetters = groups.flat();
    const flat = chordLetters.join("");
    const firstKey = chordLetters[0];
    const lastLetter = chordLetters[chordLetters.length - 1];
    const early = chordLetters.slice(0, Math.min(3, chordLetters.length));
    const boosts = this.userBoosts.get(this.chordKey(groups)) || new Map();

    const indexSet = new Set();
    for (const f of groups[0]) {
      for (const i of this.byFirst.get(f) || []) indexSet.add(i);
    }
    const results = [];
    for (const i of indexSet) {
      const e = this.entries[i];
      if (e.folded.length < chordLetters.length) continue;
      const w = e.folded;
      if (!ChordEngine.matches(w, groups)) continue;
      let score = e.logFreq;
      if (w === flat && !chorded) score += SCORE.exactBonus;
      if (w[0] === firstKey) score += SCORE.firstKeyBonus;
      if (ChordEngine.isPlainSubsequence(chordLetters, w)) score += SCORE.typedOrderBonus;
      const window = w.slice(0, 4);
      if (early.every((ch) => window.includes(ch))) score += SCORE.earlyWindowBonus;
      if (lastLetter && w[w.length - 1] === lastLetter) score += SCORE.lastLetterBonus;
      score -= SCORE.extraLetterPenalty * (w.length - chordLetters.length);
      const n = boosts.get(e.word);
      if (n) score += SCORE.userBoost * Math.min(n, 3);
      results.push({ word: e.word, score });
    }
    results.sort((a, b) => b.score - a.score);
    return results.slice(0, limit);
  }

  isAmbiguous(cands) {
    return cands.length >= 2 && cands[0].score - cands[1].score < SCORE.ambiguityMargin;
  }

  learn(groups, chosen) {
    const key = this.chordKey(groups);
    if (!this.userBoosts.has(key)) this.userBoosts.set(key, new Map());
    const m = this.userBoosts.get(key);
    m.set(chosen, (m.get(chosen) || 0) + 1);
  }
}

if (typeof module !== "undefined") module.exports = { ChordEngine, foldAccents, SCORE };
