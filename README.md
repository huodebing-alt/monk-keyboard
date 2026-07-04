# Comp — the chord typing keyboard. Type whole words in one stroke.

**Comp is a free, open-source keyboard (IME / input method) for macOS that lets you type entire words in a single keystroke.** Instead of typing `a` `p` `p` `l` `e` one letter at a time, you press **A+P+L together** — a *chord* — hit space, and Comp fills in **apple**. It's the fastest way to type on a normal keyboard: no special hardware, no stenography course, no abbreviations to memorize. The chord for a word is the word's own letters.

> In jazz, *comping* is what the pianist does behind a soloist: playing chords, not single notes. Comp does the same for your typing — you play the chord, it completes the word.

**[🎮 Learn it in the browser — Comp Trainer](https://huodebing-alt.github.io/comp-keyboard/webapp/)** · **[📄 Read the design paper](docs/PAPER.md)** ([PDF](docs/comp-paper.pdf)) · **[⬇️ Download for macOS](https://github.com/huodebing-alt/comp-keyboard/releases/latest)**

---

## How chord typing works

| You press | Comp types |
|---|---|
| `A+P+L` + space | **apple** |
| `T+H` + space | **the** |
| `K+B+D` + space | **keyboard** |
| `T+M+R+W` + space | **tomorrow** |
| `a` `p` `p` `l` `e` (typed normally) + space | **apple** — normal typing always passes through untouched |

Comp infers the most likely word from your chord **and the context of what you're writing**, using a frequency language model with optional LLM (Claude) re-ranking. In the rare case a chord genuinely matches more than one likely word, a candidate bar appears under your cursor — pick with `1`–`9`, `←`/`→`, or just hit space for the top choice. Every choice you make is learned, so your personal vocabulary resolves instantly next time.

**Rule of thumb for a good chord:** first letter + a strong middle consonant + last letter.

## Why it's fast (the math)

From the [design paper](docs/PAPER.md):

- Chorded entry needs only **2.9 key presses per word** in English vs 3.8 for full typing — **21–25% fewer keystrokes** across all six supported languages, *before* counting that those presses collapse into one simultaneous stroke.
- A keystroke-level motor model puts the practical ceiling near **2× your sequential typing speed** (~145 WPM at ordinary finger speed).
- ~80% of the 10,000 most common English words resolve uniquely from a chord shorter than the word itself; the candidate bar covers the rest.

## Install on macOS

**Option A — installer package (system-wide):**

1. Download `Comp-x.y.z-macos.pkg` from [Releases](https://github.com/huodebing-alt/comp-keyboard/releases/latest) and run it.
2. Open **System Settings → Keyboard → Text Input → Input Sources → Edit**, click **+**, choose **English → Comp**, click **Add**. (Log out and back in if Comp doesn't appear.)
3. Switch to Comp from the input menu (or `Ctrl+Space`) and start chording.

**Option B — zip (per-user, no admin rights):**

```bash
unzip Comp-*-macos.zip && ./install.sh
```

**Build from source:**

```bash
git clone https://github.com/huodebing-alt/comp-keyboard.git
cd comp-keyboard && ./macos/build.sh   # requires Xcode Command Line Tools
```

> The app is ad-hoc signed (not notarized). If macOS complains, the zip's `install.sh` clears the quarantine flag for you.

### Optional: LLM context re-ranking

Create `~/Library/Application Support/Comp/config.json`:

```json
{ "apiKey": "sk-ant-...", "model": "claude-haiku-4-5-20251001", "languages": ["en"], "chordWindowMs": 45 }
```

With an API key set, ambiguous chords are re-ranked by Claude using your recent words as context — `A+P` after "she bit into the" becomes *apple*, not *approach*. Without a key, everything runs 100% locally and offline.

## Learn it as a game

**[Comp Trainer](https://huodebing-alt.github.io/comp-keyboard/webapp/)** teaches chord typing in five jazz sets — Warm-Up, Duets, Trio, Standards, Improv — with live WPM, keystrokes-saved and streak meters. It runs the *identical* inference engine as the keyboard, so skills transfer one-to-one. Works in any browser, nothing to install. (Or open `webapp/index.html` from this repo behind any static server.)

## Supported languages

English, Spanish (Español), French (Français), German (Deutsch), Italian (Italiano), Portuguese (Português) — with accent-folded matching (type `cafe`, get `café`). The dictionary pipeline (`tools/build_dicts.py`) builds from any word-frequency list, so adding a Latin-script language is a one-liner. Chinese/Japanese via pinyin/romaji chords are on the roadmap (see paper §9).

## How it compares

| | Comp | Autocomplete | T9 / swipe | Stenotype |
|---|---|---|---|---|
| Whole word in one stroke | ✅ | ❌ | ❌ / touch-only | ✅ |
| Standard keyboard | ✅ | ✅ | ❌ | ❌ |
| Zero code to memorize | ✅ | ✅ | ✅ | ❌ (months of training) |
| Normal typing unaffected | ✅ | ⚠️ | ❌ | ❌ |
| Context-aware (LLM) | ✅ opt-in | varies | ❌ | ❌ |

## FAQ

**What is chord typing?** Pressing several letter keys simultaneously to enter a whole word at once, the way a court stenographer or a jazz pianist plays a chord. Comp decodes the chord into the intended word probabilistically.

**Do I have to change how I type?** No. Comp is strictly additive: full words typed normally always commit exactly as typed. Chord when you want speed, type normally when you don't.

**What happens when a chord is ambiguous?** A small bar appears under the cursor listing the matching words; choose with a number key, arrow keys, or space. Comp remembers your choice.

**Is my typing sent anywhere?** No. Inference is fully local. The optional Claude re-ranking only activates if you add your own API key, and only sends the last few words plus the candidate list when a chord is ambiguous.

**Which platforms?** macOS today (InputMethodKit). The engine is ~200 lines of portable logic with a reference JavaScript port in [`webapp/engine.js`](webapp/engine.js) — Windows (TSF) and Linux (IBus/Fcitx) ports are welcome contributions.

## Project layout

```
macos/         Swift InputMethodKit input method + build/packaging scripts
webapp/        Comp Trainer — browser typing game (same engine, JS)
dictionaries/  Frequency lexicons (6 languages) + raw corpus lists
tools/         Dictionary builder + disambiguation analysis (paper stats)
docs/          Design paper (Markdown + PDF) and per-language statistics
```

## The design paper

The full design — interaction model, log-linear scoring, entropy analysis, chord-window classifier, motor-model speed ceiling, and per-language keystroke statistics — is in **[docs/PAPER.md](docs/PAPER.md)** ([PDF](docs/comp-paper.pdf)): *"Comp: Chord-Ahead Text Entry with Probabilistic Word Inference."*

## License

[MIT](LICENSE). Dictionaries derived from the [FrequencyWords](https://github.com/hermitdave/FrequencyWords) compilation of OpenSubtitles corpora (CC-BY-SA-4.0).

---

*Keywords: chord typing, chorded keyboard, fastest keyboard app, typing speed, macOS IME, input method, word prediction, LLM keyboard, stenography for QWERTY, type faster, keyboard shortcuts for words, predictive text, open source keyboard.*
