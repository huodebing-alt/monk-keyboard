<p align="center">
  <img src="webapp/logo.svg" alt="Monk — ensō logo" width="120" />
</p>

# Monk — the chord typing keyboard. Type whole words in one stroke.

**Monk is a free, open-source keyboard (IME / input method) for macOS that lets you type entire words in a single keystroke.** Instead of typing `a` `p` `p` `l` `e` one letter at a time, you press **A+P+L together** — a *chord* — hit space, and Monk fills in **apple**. It's the fastest way to type on a normal keyboard: no special hardware, no stenography course, no abbreviations to memorize. The chord for a word is the word's own letters.

**[🎮 Learn it in the browser — Monk Trainer](https://huodebing-alt.github.io/monk-keyboard/webapp/)** · **[📄 Read the design paper](docs/PAPER.md)** ([PDF](docs/monk-paper.pdf)) · **[⬇️ Download for macOS](https://github.com/huodebing-alt/monk-keyboard/releases/latest)**

## Why "Monk"?

Named for **Thelonious Monk**, the jazz pianist who played chords instead of runs and was famous for the notes he *left out* — trusting the harmonic context to make you hear them anyway. That is exactly this keyboard's deal with you: strike a few letters of a word as one chord, leave the rest out, and the language model — the harmonic context — fills in what was implied. Monk said *"the piano ain't got no wrong notes."* On this keyboard, neither does the chord. The logo is an ensō — one brush stroke, left open — around a single keycap: **one stroke, one word.**

## How chord typing works

| You press | Monk types |
|---|---|
| `A+P+L` + space | **apple** |
| `T+H` + space | **the** |
| `D+N+T` + space | **don't** — contractions are first-class words |
| `T+M+R+W` + space | **tomorrow** |
| `Shift-T+H` + space | **The** — capitalization follows your fingers |
| `a` `p` `p` `l` `e` (typed normally) + space | **apple** — normal typing always passes through untouched |

Monk infers the most likely word from your chord **and the context of what you're writing**, using a frequency language model plus an embedded on-device LLM (SmolLM2-135M) — fully offline. In the rare case a chord genuinely matches more than one likely word, a candidate bar appears under your cursor — pick with `1`–`9`, `←`/`→`, or just hit space for the top choice. Every choice you make is learned, so your personal vocabulary resolves instantly next time.

**Rule of thumb for a good chord:** first letter + a strong middle consonant + last letter.

### Flow mode

When you'd rather never be asked, turn on **Flow mode**: the candidate bar disappears entirely and every chord commits its highest-ranking word immediately — on ambiguity, the on-device LLM makes the call from your sentence context in ~35 ms, inline. Toggle it from the **input menu → Flow Mode** (menu bar, while Monk is active), or set `"flowMode": true` in the config. Mis-guesses are just typos: retype the word (which also teaches Monk your preference). Flow is at its best after a few days of adaptation, when your personal vocabulary is already winning chords outright.

## Why it's fast (the math)

From the [design paper](docs/PAPER.md):

- **Maximum theoretical time saving: ~59%** — a chorded word costs one prepared stroke plus a space instead of ~5.7 serial keystrokes. Practical band with real ambiguity rates: **45–50%**.
- In hours: typing out the complete Harry Potter series (1,084,170 words) costs ~452 hours of keystroking at 40 WPM; at Monk's ceiling, **~265 of those hours — six working weeks — never happen**. An hour of email a day returns ~30 minutes, every day.
- Chorded entry needs only **2.9 key presses per word** in English vs 3.8 for full typing — 21–25% fewer keystrokes across all six supported languages, before counting simultaneity.
- ~80% of the 10,000 most common English words resolve uniquely from a chord shorter than the word itself; the candidate bar covers the rest.

## Install on macOS

**Option A — installer package (system-wide):**

1. Download `Monk-x.y.z-macos.pkg` from [Releases](https://github.com/huodebing-alt/monk-keyboard/releases/latest) and run it.
2. Open **System Settings → Keyboard → Text Input → Input Sources → Edit**, click **+**, choose **English → Monk**, click **Add**. (Log out and back in if Monk doesn't appear.)
3. Switch to Monk from the input menu (or `Ctrl+Space`) and start chording.

**Option B — zip (per-user, no admin rights):**

```bash
unzip Monk-*-macos.zip && ./install.sh
```

**Build from source:**

```bash
git clone https://github.com/huodebing-alt/monk-keyboard.git
cd monk-keyboard && ./macos/build.sh   # requires Xcode Command Line Tools + cmake
```

The build script fetches llama.cpp and the SmolLM2-135M weights automatically on first run.

> The app is ad-hoc signed (not notarized). If macOS complains, the zip's `install.sh` clears the quarantine flag for you.

### Built-in on-device LLM

Monk embeds **[SmolLM2-135M](https://huggingface.co/HuggingFaceTB/SmolLM2-135M)** (Apache-2.0), running via llama.cpp compiled into the app. When a chord is ambiguous, the model re-ranks the candidates by how well each continues your sentence — `A+P` after "she bit into the" becomes *apple*, not *approach* — in ~35 ms on Apple Silicon, entirely offline. No API key, no network, ever.

Optional tuning in `~/Library/Application Support/Monk/config.json`:

```json
{ "llm": true, "languages": ["en"], "chordWindowMs": 45, "flowMode": false }
```

Set `"llm": false` to disable the model and run pure frequency + adaptation ranking.

## Learn it as a game

**[Monk Trainer](https://huodebing-alt.github.io/monk-keyboard/webapp/)** teaches chord typing in five sets — Warm-Up, Duets, Trio, Standards, Improv — with live WPM, keystrokes-saved and streak meters, in a quiet black-white-grey interface. It runs the *identical* inference engine as the keyboard, so skills transfer one-to-one. Works in any browser, nothing to install. (Or open `webapp/index.html` from this repo behind any static server.)

## Supported languages

English, Spanish (Español), French (Français), German (Deutsch), Italian (Italiano), Portuguese (Português) — with accent-folded matching (type `cafe`, get `café`) and full contraction support in English (`d+n+t` → *don't*, typing `doesnt` restores *doesn't*). The dictionary pipeline (`tools/build_dicts.py`) builds from any word-frequency list, so adding a Latin-script language is a one-liner. Chinese/Japanese via pinyin/romaji chords are on the roadmap (see paper §9).

## How it compares

| | Monk | Autocomplete | T9 / swipe | Stenotype |
|---|---|---|---|---|
| Whole word in one stroke | ✅ | ❌ | ❌ / touch-only | ✅ |
| Standard keyboard | ✅ | ✅ | ❌ | ❌ |
| Zero code to memorize | ✅ | ✅ | ✅ | ❌ (months of training) |
| Normal typing unaffected | ✅ | ⚠️ | ❌ | ❌ |
| Context-aware (LLM) | ✅ on-device | varies | ❌ | ❌ |

## FAQ

**What is chord typing?** Pressing several letter keys simultaneously to enter a whole word at once, the way a court stenographer or a jazz pianist plays a chord. Monk decodes the chord into the intended word probabilistically.

**Do I have to change how I type?** No. Monk is strictly additive: full words typed normally always commit exactly as typed. Chord when you want speed, type normally when you don't.

**How do capitals work?** Hold Shift on the first key of the chord and the committed word is Capitalized; shift the whole chord for ALL CAPS.

**What happens when a chord is ambiguous?** A small bar appears under the cursor listing the matching words; choose with a number key, arrow keys, or space. Monk remembers your choice. Or turn on **Flow mode** and Monk always commits its best guess — no bar, no questions.

**Is my typing sent anywhere?** No. Everything — the frequency engine, your personal adaptation data, and the embedded SmolLM2-135M language model — runs on your machine. Monk never opens a network connection.

**Which platforms?** macOS today (InputMethodKit). The engine is ~200 lines of portable logic with a reference JavaScript port in [`webapp/engine.js`](webapp/engine.js) — Windows (TSF) and Linux (IBus/Fcitx) ports are welcome contributions.

## Project layout

```
macos/         Swift InputMethodKit input method + build/packaging scripts
webapp/        Monk Trainer — browser typing game (same engine, JS) + logo
dictionaries/  Frequency lexicons (6 languages) + raw corpus lists
tools/         Dictionary builder + disambiguation analysis (paper stats)
docs/          Design paper (Markdown + PDF) and per-language statistics
```

## The design paper

The full design — interaction model, log-linear scoring, entropy analysis, chord-window classifier, motor-model speed ceiling, maximum-time-saving analysis, and per-language keystroke statistics — is in **[docs/PAPER.md](docs/PAPER.md)** ([PDF](docs/monk-paper.pdf)): *"Monk: Chord-Ahead Text Entry with Probabilistic Word Inference"*, Lei (Lorin) Zhao, 2026.

## License

[MIT](LICENSE). Dictionaries derived from the [FrequencyWords](https://github.com/hermitdave/FrequencyWords) compilation of OpenSubtitles corpora (CC-BY-SA-4.0). Embedded model: [SmolLM2-135M](https://huggingface.co/HuggingFaceTB/SmolLM2-135M) (Apache-2.0) via [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT).

---

*Keywords: chord typing, chorded keyboard, fastest keyboard app, typing speed, macOS IME, input method, word prediction, LLM keyboard, on-device AI keyboard, stenography for QWERTY, type faster, Thelonious Monk, predictive text, open source keyboard.*
