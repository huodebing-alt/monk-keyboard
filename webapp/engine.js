/* Monk chord-inference engine — JavaScript port of macos/Sources/ChordEngine.swift.
 * Keep the scoring constants in sync with the Swift implementation. */

const SCORE = {
  exactBonus: 40.0,
  lastLetterBonus: 3.0,
  firstKeyBonus: 4.0,
  typedOrderBonus: 2.5,
  earlyWindowBonus: 2.0,
  extraLetterPenalty: 0.22,
  // a chord is a deliberate compression of the word, so letters it leaves
  // uncovered cost more than in sequential prefix entry
  chordedExtraLetterPenalty: 0.8,
  userBoost: 6.0,
  ambiguityMargin: 1.5,
  // wider margin for chorded input: intra-group arrival order is rollover
  // noise, so order-derived gaps there shouldn't commit silently — near
  // ties go to the bar (or the LM re-ranker in the macOS keyboard) instead
  chordedAmbiguityMargin: 3.0,
  // pool seats reserved for the best *order-free* interpretations of a
  // chord, so arrival-order bonuses can never crowd them out entirely
  orderFreeSeats: 6,
};

function foldAccents(s) {
  return s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/['’]/g, "");
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
    // early letters: only whole groups within the first three keys count —
    // a partial slice of a chorded group would be rollover noise
    const early = [];
    for (const g of groups) {
      if (early.length + g.length > 3) break;
      early.push(...g);
      if (early.length >= 3) break;
    }
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
      let orderBonus = 0;
      if (w[0] === firstKey) orderBonus += SCORE.firstKeyBonus;
      if (ChordEngine.isPlainSubsequence(chordLetters, w)) orderBonus += SCORE.typedOrderBonus;
      const window = w.slice(0, 4);
      if (early.every((ch) => window.includes(ch))) score += SCORE.earlyWindowBonus;
      // within a chorded final group any letter may be the word's ending —
      // unless that letter is the single key already serving as the onset
      const lastGroup = groups[groups.length - 1];
      const wl = w[w.length - 1];
      if (lastGroup.length > 1) {
        const consumedByOnset = groups.length === 1 && wl === w[0];
        if (lastGroup.includes(wl) && !consumedByOnset) score += SCORE.lastLetterBonus;
      } else if (wl === lastGroup[0]) {
        score += SCORE.lastLetterBonus;
      }
      score -= (chorded ? SCORE.chordedExtraLetterPenalty : SCORE.extraLetterPenalty) *
        (w.length - chordLetters.length);
      const n = boosts.get(e.word);
      if (n) score += SCORE.userBoost * Math.min(n, 3);
      // orderFreeScore: what the letter *set* alone says — for chorded
      // input this is the order-noise-free evidence
      results.push({ word: e.word, score: score + orderBonus, orderFreeScore: score });
    }
    results.sort((a, b) => b.score - a.score);
    if (!chorded) return results.slice(0, limit);
    // a chorded press carries no reliable intra-group order, so the best
    // order-free (letter-set) readings get guaranteed pool seats
    const picked = [];
    const seen = new Set();
    const byOrderFree = results.slice().sort((a, b) => b.orderFreeScore - a.orderFreeScore);
    for (const c of byOrderFree.slice(0, Math.min(SCORE.orderFreeSeats, limit))) {
      picked.push(c);
      seen.add(c.word);
    }
    for (const c of results) {
      if (picked.length >= limit) break;
      if (!seen.has(c.word)) { seen.add(c.word); picked.push(c); }
    }
    picked.sort((a, b) => b.score - a.score);
    return picked;
  }

  isAmbiguous(cands, chorded = false) {
    if (cands.length < 2) return false;
    const gap = cands[0].score - cands[1].score;
    if (!chorded) return gap < SCORE.ambiguityMargin;
    // for chorded input, also judge the gap with arrival-order bonuses
    // removed: a lead built on rollover order is not a real lead
    const of = cands.map((c) => c.orderFreeScore).sort((a, b) => b - a);
    return Math.min(gap, of[0] - of[1]) < SCORE.chordedAmbiguityMargin;
  }

  learn(groups, chosen) {
    const key = this.chordKey(groups);
    if (!this.userBoosts.has(key)) this.userBoosts.set(key, new Map());
    const m = this.userBoosts.get(key);
    m.set(chosen, (m.get(chosen) || 0) + 1);
  }
}

if (typeof module !== "undefined") module.exports = { ChordEngine, foldAccents, SCORE };
