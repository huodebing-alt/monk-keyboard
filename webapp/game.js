/* Comp Trainer — a jazz-set typing game that teaches chord typing.
 * Mirrors the behavior of the Comp macOS input method. */

const CHORD_WINDOW_MS = 60;

const SETS = [
  {
    id: "warmup", name: "1. Warm-Up", desc: "Two-key chords on the words you type most.",
    kind: "words", chordMin: 2, count: 10,
  },
  {
    id: "duets", name: "2. Duets", desc: "Short words, two keys at once. Find the groove.",
    kind: "words", chordMin: 2, count: 14,
  },
  {
    id: "trio", name: "3. Trio", desc: "Three-key chords. First, salient, last.",
    kind: "words", chordMin: 3, count: 14,
  },
  {
    id: "standards", name: "4. Standards", desc: "Full phrases, chord every word.",
    kind: "sentences", chordMin: 0, count: 4,
  },
  {
    id: "improv", name: "5. Improv", desc: "Free solo. Race the clock, watch your WPM.",
    kind: "sentences", chordMin: 0, count: 6,
  },
];

const SENTENCES = {
  en: [
    "take the train to the city tonight",
    "she plays the piano after midnight",
    "the band swings hard and the crowd loves it",
    "autumn leaves fall on the quiet street",
    "we should record this song before morning",
    "there is always time for one more chorus",
    "the trumpet player took a long solo",
    "keep the rhythm steady and follow the bass",
  ],
  es: [
    "toma el tren a la ciudad esta noche",
    "ella toca el piano despues de medianoche",
    "la banda suena fuerte y al publico le encanta",
    "las hojas caen sobre la calle tranquila",
    "siempre hay tiempo para una cancion mas",
    "el ritmo sigue firme toda la noche",
  ],
  fr: [
    "prends le train pour la ville ce soir",
    "elle joue du piano apres minuit",
    "le groupe joue fort et le public adore",
    "les feuilles tombent sur la rue calme",
    "il y a toujours du temps pour un morceau de plus",
    "garde le rythme et suis la basse",
  ],
  de: [
    "nimm den zug in die stadt heute nacht",
    "sie spielt klavier nach mitternacht",
    "die band spielt stark und das publikum liebt es",
    "im herbst fallen die blaetter auf die strasse",
    "es ist immer zeit fuer ein weiteres lied",
    "halte den rhythmus und folge dem bass",
  ],
  it: [
    "prendi il treno per la citta stasera",
    "lei suona il piano dopo mezzanotte",
    "la banda suona forte e al pubblico piace",
    "le foglie cadono sulla strada tranquilla",
    "c'e sempre tempo per una canzone in piu",
    "tieni il ritmo e segui il basso",
  ],
  pt: [
    "pegue o trem para a cidade hoje a noite",
    "ela toca piano depois da meia noite",
    "a banda toca forte e o publico adora",
    "as folhas caem na rua tranquila",
    "sempre ha tempo para mais uma musica",
    "segure o ritmo e siga o baixo",
  ],
};

const LANG_NAMES = { en: "English", es: "Español", fr: "Français", de: "Deutsch", it: "Italiano", pt: "Português" };

// ---------------------------------------------------------------- state

const engine = new ChordEngine();
let lang = "en";
let dictLoaded = false;
let screen = "menu"; // menu | game | results
let currentSet = null;
let progress = JSON.parse(localStorage.getItem("comp-progress") || "{}");

const S = {
  targets: [], targetIdx: 0, wordIdx: 0,
  committed: "", keystrokes: [], candidates: [], selected: 0,
  awaitingSelection: false,
  keysPressed: 0, lettersOutput: 0, wordsDone: 0, chordsUsed: 0,
  startTime: 0, mistakes: 0,
};

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- dictionary

async function loadDict(l) {
  dictLoaded = false;
  const res = await fetch(`dict/${l}.json`);
  engine.load(await res.json());
  dictLoaded = true;
}

// ---------------------------------------------------------------- chord groups

function groupsFromKeystrokes(ks) {
  const groups = [];
  for (let i = 0; i < ks.length; i++) {
    if (i > 0 && ks[i].t - ks[i - 1].t < CHORD_WINDOW_MS) {
      groups[groups.length - 1].push(ks[i].ch);
    } else {
      groups.push([ks[i].ch]);
    }
  }
  return groups;
}

const hasChord = (groups) => groups.some((g) => g.length > 1);

// ---------------------------------------------------------------- set content

function buildTargets(set) {
  if (set.kind === "sentences") {
    const pool = SENTENCES[lang] || SENTENCES.en;
    const shuffled = pool.slice().sort(() => Math.random() - 0.5);
    return shuffled.slice(0, set.count);
  }
  // word sets: pick frequent words, length suited to the chord size being taught
  const minLen = set.chordMin === 2 ? 3 : 5;
  const maxLen = set.chordMin === 2 ? 6 : 10;
  const words = engine.entries
    .slice(0, 900)
    .map((e) => e.word)
    .filter((w) => w.length >= minLen && w.length <= maxLen && /^[a-z]+$/.test(foldAccents(w)));
  const picked = [];
  const used = new Set();
  while (picked.length < set.count && words.length) {
    const w = words[Math.floor(Math.random() * Math.min(words.length, 400))];
    if (!used.has(w)) { used.add(w); picked.push(w); }
  }
  return picked;
}

function chordHint(word) {
  const folded = foldAccents(word);
  if (folded.length <= 2) return folded;
  if (folded.length <= 4) return folded[0] + folded[1];
  // first + a middle consonant + last
  const mid = folded.slice(1, -1).replace(/[aeiou]/g, "");
  const middle = mid ? mid[Math.floor(mid.length / 2)] : folded[1];
  return folded[0] + middle + folded[folded.length - 1];
}

// ---------------------------------------------------------------- rendering

function show(id) {
  for (const s of ["menu", "game", "results"]) $(s).style.display = s === id ? "block" : "none";
  screen = id;
}

function renderMenu() {
  const row = $("langs");
  row.innerHTML = "";
  for (const l of Object.keys(LANG_NAMES)) {
    const b = document.createElement("button");
    b.textContent = LANG_NAMES[l];
    b.className = l === lang ? "active" : "";
    b.onclick = async () => { lang = l; await loadDict(l); renderMenu(); };
    row.appendChild(b);
  }
  const sets = $("sets");
  sets.innerHTML = "";
  SETS.forEach((set, i) => {
    const stars = progress[`${lang}:${set.id}`] || 0;
    const locked = i > 0 && !(progress[`${lang}:${SETS[i - 1].id}`] > 0);
    const card = document.createElement("button");
    card.className = "set-card" + (locked ? " locked" : "");
    card.innerHTML = `<h3>${set.name}</h3><p>${set.desc}</p>
      <div class="stars">${"★".repeat(stars)}${"☆".repeat(3 - stars)}</div>`;
    if (!locked) card.onclick = () => startSet(set);
    sets.appendChild(card);
  });
}

function currentTargetWords() {
  return S.targets[S.targetIdx].split(" ");
}

function renderTarget() {
  const words = currentTargetWords();
  $("target").innerHTML = words
    .map((w, i) => {
      const cls = i < S.wordIdx ? "done" : i === S.wordIdx ? "current" : "todo";
      return `<span class="${cls}">${w}</span>`;
    })
    .join(" ");
  const cur = words[S.wordIdx];
  if (cur && currentSet.chordMin > 0) {
    const hint = chordHint(cur);
    $("hint").innerHTML =
      `Try the chord <b>${hint.toUpperCase().split("").join(" + ")}</b> — press them together, then <b>space</b>.`;
  } else if (cur) {
    $("hint").innerHTML = `Chord each word, <b>space</b> to commit. Full typing works too.`;
  }
}

function renderTypebox() {
  const buf = S.keystrokes.map((k) => k.ch).join("");
  $("typebox").innerHTML =
    `<span class="committed">${S.committed}</span>` +
    `<span class="buffer">${buf}</span><span class="caret"></span>`;
}

function renderCandidates() {
  const bar = $("candbar");
  bar.innerHTML = "";
  if (!S.keystrokes.length || !S.candidates.length) return;
  S.candidates.slice(0, 6).forEach((c, i) => {
    const div = document.createElement("div");
    div.className = "cand" + (S.awaitingSelection && i === S.selected ? " selected" : "");
    div.innerHTML = `<span class="idx">${i + 1}</span>${c.word}`;
    div.onclick = () => commitWord(c.word, true);
    bar.appendChild(div);
  });
  if (S.awaitingSelection) {
    const n = document.createElement("span");
    n.className = "amb-note";
    n.textContent = "ambiguous — pick with 1-9, ←/→, or space for the highlighted one";
    bar.appendChild(n);
  }
}

function renderChordViz(groups) {
  const viz = $("chordviz");
  viz.innerHTML = "";
  groups.forEach((g, gi) => {
    if (gi > 0) {
      const plus = document.createElement("span");
      plus.className = "plus"; plus.textContent = "·";
      viz.appendChild(plus);
    }
    for (const ch of g) {
      const k = document.createElement("div");
      k.className = "key" + (g.length > 1 ? " chorded" : "");
      k.textContent = ch.toUpperCase();
      viz.appendChild(k);
    }
  });
}

function renderHUD() {
  const mins = (Date.now() - S.startTime) / 60000;
  const wpm = mins > 0 ? Math.round(S.wordsDone / mins) : 0;
  const saved = S.keysPressed > 0
    ? Math.max(0, Math.round(100 * (1 - S.keysPressed / Math.max(1, S.lettersOutput + S.wordsDone))))
    : 0;
  $("stat-wpm").textContent = wpm;
  $("stat-saved").textContent = saved + "%";
  $("stat-combo").textContent = S.combo || 0;
  $("hud-combo").className = "stat combo" + ((S.combo || 0) >= 5 ? " hot" : "");
  $("stat-left").textContent = `${S.targetIdx + 1}/${S.targets.length}`;
}

function flyNote(x, y) {
  const n = document.createElement("div");
  n.className = "fly-note";
  n.textContent = ["♪", "♫", "♩", "♬"][Math.floor(Math.random() * 4)];
  n.style.left = (x || window.innerWidth / 2 + (Math.random() * 120 - 60)) + "px";
  n.style.top = (y || window.innerHeight / 2) + "px";
  $("notes").appendChild(n);
  setTimeout(() => n.remove(), 1300);
}

// ---------------------------------------------------------------- game flow

async function startSet(set) {
  if (!dictLoaded) await loadDict(lang);
  currentSet = set;
  Object.assign(S, {
    targets: buildTargets(set), targetIdx: 0, wordIdx: 0,
    committed: "", keystrokes: [], candidates: [], selected: 0,
    awaitingSelection: false, keysPressed: 0, lettersOutput: 0,
    wordsDone: 0, chordsUsed: 0, startTime: Date.now(), mistakes: 0, combo: 0,
  });
  show("game");
  $("set-title").textContent = set.name.replace(/^\d+\. /, "");
  renderTarget(); renderTypebox(); renderCandidates(); renderHUD();
  $("feedback").innerHTML = "";
  renderChordViz([]);
}

function refresh() {
  const groups = groupsFromKeystrokes(S.keystrokes);
  S.candidates = S.keystrokes.length ? engine.candidates(groups) : [];
  S.selected = 0;
  renderTypebox(); renderCandidates(); renderChordViz(groups); renderHUD();
}

function commitWord(word, learned) {
  const groups = groupsFromKeystrokes(S.keystrokes);
  if (learned && S.keystrokes.length) engine.learn(groups, word);
  if (hasChord(groups)) S.chordsUsed++;

  const targetWords = currentTargetWords();
  const expected = targetWords[S.wordIdx];
  S.keystrokes = [];
  S.candidates = [];
  S.awaitingSelection = false;

  if (foldAccents(word) === foldAccents(expected)) {
    S.committed += word + " ";
    S.wordIdx++;
    S.wordsDone++;
    S.lettersOutput += word.length;
    S.combo = (S.combo || 0) + 1;
    $("feedback").innerHTML = `<span class="good">✓ ${word}</span>`;
    flyNote();
    if (S.wordIdx >= targetWords.length) {
      S.targetIdx++;
      S.wordIdx = 0;
      S.committed = "";
      if (S.targetIdx >= S.targets.length) return endSet();
      renderTarget();
    }
  } else {
    S.mistakes++;
    S.combo = 0;
    $("feedback").innerHTML =
      `<span class="bad">✗ got “${word}” — wanted “${expected}”. Add one more letter to the chord.</span>`;
  }
  renderTarget(); refresh();
}

function endSet() {
  const mins = (Date.now() - S.startTime) / 60000;
  const wpm = Math.round(S.wordsDone / Math.max(mins, 0.01));
  const acc = S.wordsDone / Math.max(1, S.wordsDone + S.mistakes);
  const saved = Math.max(0, Math.round(100 * (1 - S.keysPressed / Math.max(1, S.lettersOutput + S.wordsDone))));
  let stars = 1;
  if (acc >= 0.85 && S.chordsUsed >= S.wordsDone * 0.4) stars = 2;
  if (acc >= 0.95 && S.chordsUsed >= S.wordsDone * 0.6 && wpm >= 25) stars = 3;
  const key = `${lang}:${currentSet.id}`;
  progress[key] = Math.max(progress[key] || 0, stars);
  localStorage.setItem("comp-progress", JSON.stringify(progress));

  $("res-stars").textContent = "★".repeat(stars) + "☆".repeat(3 - stars);
  $("res-wpm").textContent = wpm;
  $("res-saved").textContent = saved + "%";
  $("res-acc").textContent = Math.round(acc * 100) + "%";
  $("res-chords").textContent = S.chordsUsed;
  $("res-line").textContent =
    stars === 3 ? "You're gigging. Take another chorus." :
    stars === 2 ? "Solid comping. Push the tempo." :
    "Keep shedding — chords come with muscle memory.";
  show("results");
}

// ---------------------------------------------------------------- input

document.addEventListener("keydown", (e) => {
  if (screen !== "game") return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;

  const key = e.key;

  if (key === "Backspace") {
    e.preventDefault();
    if (S.keystrokes.length) { S.keystrokes.pop(); S.awaitingSelection = false; refresh(); }
    return;
  }
  if (key === "Escape") {
    e.preventDefault();
    S.keystrokes = []; S.awaitingSelection = false; refresh();
    return;
  }
  if (S.awaitingSelection) {
    if (key === "ArrowRight" || key === "ArrowDown") {
      e.preventDefault();
      S.selected = Math.min(S.selected + 1, Math.min(S.candidates.length, 6) - 1);
      renderCandidates(); return;
    }
    if (key === "ArrowLeft" || key === "ArrowUp") {
      e.preventDefault();
      S.selected = Math.max(S.selected - 1, 0);
      renderCandidates(); return;
    }
    if (key === "Enter") {
      e.preventDefault();
      commitWord(S.candidates[S.selected].word, true); return;
    }
  }
  if (/^[1-9]$/.test(key) && S.candidates.length && S.keystrokes.length) {
    const i = parseInt(key, 10) - 1;
    if (i < Math.min(S.candidates.length, 6)) {
      e.preventDefault();
      commitWord(S.candidates[i].word, true); return;
    }
  }
  if (key === " ") {
    e.preventDefault();
    if (!S.keystrokes.length) return;
    S.keysPressed++;
    if (S.awaitingSelection) { commitWord(S.candidates[S.selected].word, true); return; }
    const groups = groupsFromKeystrokes(S.keystrokes);
    const buf = S.keystrokes.map((k) => k.ch).join("");
    if (!S.candidates.length) { commitWord(buf, false); return; }
    if (engine.isWord(buf) && !hasChord(groups)) { commitWord(buf, false); return; }
    if (engine.isAmbiguous(S.candidates)) {
      S.awaitingSelection = true; S.selected = 0;
      renderCandidates(); return;
    }
    commitWord(S.candidates[0].word, S.candidates[0].word !== buf);
    return;
  }
  if (key.length === 1 && /[a-zà-öø-ÿœß]/i.test(key)) {
    e.preventDefault();
    S.keysPressed++;
    S.keystrokes.push({ ch: key.toLowerCase(), t: performance.now() });
    S.awaitingSelection = false;
    refresh();
  }
});

// ---------------------------------------------------------------- boot

$("btn-again").onclick = () => startSet(currentSet);
$("btn-menu").onclick = () => { renderMenu(); show("menu"); };
$("btn-quit").onclick = () => { renderMenu(); show("menu"); };

(async function boot() {
  await loadDict(lang);
  renderMenu();
  show("menu");
})();
