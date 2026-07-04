import Cocoa
import InputMethodKit

@objc(MonkInputController)
class MonkInputController: IMKInputController {

    // one engine shared by every client (Mail, Safari, ...)
    static var engine: ChordEngine = {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        let support = MonkInputController.supportDir()
        let config = MonkInputController.loadConfig()
        let langs = (config["languages"] as? [String]) ?? ["en"]
        return ChordEngine(languages: langs,
                           resourceDir: resources.appendingPathComponent("dict"),
                           supportDir: support)
    }()
    static var llm: LocalRanker? = LocalRanker(
        config: MonkInputController.loadConfig(),
        resourceDir: Bundle.main.resourceURL ?? URL(fileURLWithPath: "."))
    static var chordWindow: TimeInterval = {
        let config = MonkInputController.loadConfig()
        let ms = (config["chordWindowMs"] as? Double) ?? 45
        return ms / 1000.0
    }()
    /// Flow mode: never show the candidate bar — always commit the highest-
    /// ranking word. Toggled from the input menu, persisted in config.json.
    static var flowMode: Bool = {
        (MonkInputController.loadConfig()["flowMode"] as? Bool) ?? false
    }() {
        didSet {
            if flowMode { MonkInputController.llm?.preload() }
            saveConfigValue("flowMode", flowMode)
        }
    }

    static func saveConfigValue(_ key: String, _ value: Any) {
        var config = loadConfig()
        config[key] = value
        let file = supportDir().appendingPathComponent("config.json")
        if let data = try? JSONSerialization.data(withJSONObject: config,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file)
        }
    }

    static func supportDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Monk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func loadConfig() -> [String: Any] {
        let file = supportDir().appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    // MARK: - state

    private struct Keystroke {
        let char: Character   // lowercase letter, or "'"
        let upper: Bool
        let time: TimeInterval
    }

    private var keystrokes: [Keystroke] = []
    private var currentCandidates: [Candidate] = []
    private var contextWords: [String] = []
    private var awaitingSelection = false

    /// chord groups for the engine: letters only, apostrophes excluded
    private var groups: [ChordGroup] {
        var out: [ChordGroup] = []
        var lastTime: TimeInterval? = nil
        for k in keystrokes where k.char != "'" {
            if let lt = lastTime, k.time - lt < MonkInputController.chordWindow, !out.isEmpty {
                out[out.count - 1].letters.append(k.char)
            } else {
                out.append(ChordGroup(letters: [k.char]))
            }
            lastTime = k.time
        }
        return out
    }

    /// buffer as the user typed it, original case and apostrophes
    private var bufferString: String {
        String(keystrokes.map { k -> Character in
            k.upper ? Character(String(k.char).uppercased()) : k.char
        })
    }

    private var hasChord: Bool { groups.contains { $0.letters.count > 1 } }

    /// mirror the user's capitalization onto an inferred word:
    /// first key shifted -> Capitalized, all keys shifted -> ALL CAPS
    private func applyCase(_ word: String) -> String {
        let letterKeys = keystrokes.filter { $0.char != "'" }
        guard let first = letterKeys.first else { return word }
        if letterKeys.count >= 2 && letterKeys.allSatisfy({ $0.upper }) {
            return word.uppercased()
        }
        if first.upper {
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return word
    }

    // MARK: - IMK plumbing

    override func recognizedEvents(_ sender: Any!) -> Int {
        return Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Monk")
        let item = NSMenuItem(title: "Flow Mode",
                              action: #selector(toggleFlowMode(_:)),
                              keyEquivalent: "")
        item.target = self
        item.state = MonkInputController.flowMode ? .on : .off
        menu.addItem(item)
        return menu
    }

    @objc func toggleFlowMode(_ sender: Any?) {
        MonkInputController.flowMode.toggle()
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }
        guard let client = sender as? IMKTextInput else { return false }

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            commitRaw(client)
            return false
        }

        let keyCode = Int(event.keyCode)
        switch keyCode {
        case 51: // backspace
            if keystrokes.isEmpty { return false }
            keystrokes.removeLast()
            awaitingSelection = false
            refresh(client)
            return true
        case 53: // escape
            if keystrokes.isEmpty { return false }
            commitRaw(client)
            return true
        case 36, 76: // return / enter
            if keystrokes.isEmpty { return false }
            if awaitingSelection, !currentCandidates.isEmpty {
                commit(currentCandidates[0].word + " ", client, learned: true)
            } else {
                commitRaw(client)
            }
            return true
        case 123, 124, 125, 126: // arrows
            if awaitingSelection, let panel = MonkApp.candidatesPanel {
                panel.interpretKeyEvents([event])
                return true
            }
            if !keystrokes.isEmpty { commitRaw(client) }
            return false
        default:
            break
        }

        guard let chars = event.characters, chars.count == 1,
              let ch = chars.first else {
            if !keystrokes.isEmpty { commitRaw(client) }
            return false
        }

        // digit selection while the bar is up
        if let d = ch.wholeNumberValue, (1...9).contains(d),
           awaitingSelection || (!currentCandidates.isEmpty && !keystrokes.isEmpty && hasChord) {
            if d - 1 < currentCandidates.count {
                commit(currentCandidates[d - 1].word + " ", client, learned: true)
                return true
            }
        }

        if ch == " " {
            if keystrokes.isEmpty { return false }
            return commitBest(client, appendSpace: true)
        }

        if ch.isLetter {
            let lower = Character(String(ch).lowercased())
            let isKnownLetter = (lower.isASCII && lower.isLetter)
                || "àâäáãåçéèêëíìîïñóòôöõúùûüÿœß".contains(lower)
            if isKnownLetter {
                keystrokes.append(Keystroke(char: lower, upper: ch.isUppercase,
                                            time: event.timestamp))
                awaitingSelection = false
                refresh(client)
                return true
            }
        }

        // word-internal apostrophe joins the buffer ("doesn't", "l'heure")
        if (ch == "'" || ch == "’") && !keystrokes.isEmpty {
            keystrokes.append(Keystroke(char: "'", upper: false, time: event.timestamp))
            awaitingSelection = false
            refresh(client)
            return true
        }

        // punctuation: resolve the buffer, then pass the character through
        if !keystrokes.isEmpty {
            if ",.;:!?)]}\"".contains(ch) {
                _ = commitBest(client, appendSpace: false)
            } else {
                commitRaw(client)
            }
        }
        return false
    }

    // MARK: - inference + display

    private func refresh(_ client: IMKTextInput) {
        if keystrokes.isEmpty {
            currentCandidates = []
            setMarked("", client)
            MonkApp.candidatesPanel?.hide()
            return
        }
        currentCandidates = MonkInputController.engine.candidates(groups: groups)
        setMarked(bufferString, client)
        let foldedBuffer = ChordEngine.fold(bufferString)
        if !MonkInputController.flowMode && !currentCandidates.isEmpty &&
            (hasChord || ChordEngine.fold(currentCandidates.first!.word) != foldedBuffer) {
            MonkApp.candidatesPanel?.update()
            MonkApp.candidatesPanel?.show()
        } else {
            MonkApp.candidatesPanel?.hide()
        }
    }

    /// Space pressed: commit the winner, or open selection if ambiguous.
    private func commitBest(_ client: IMKTextInput, appendSpace: Bool) -> Bool {
        let engine = MonkInputController.engine
        let suffix = appendSpace ? " " : ""
        guard !currentCandidates.isEmpty else {
            commit(bufferString + suffix, client, learned: false, applyCasing: false)
            return true
        }
        // buffer typed fully and is a real word -> identity, stay out of the way
        if !hasChord {
            if engine.isWord(bufferString) {
                commit(bufferString + suffix, client, learned: false, applyCasing: false)
                return true
            }
            // "doesnt" typed plainly -> restore the lexicon form "doesn't"
            if let display = engine.displayForm(folded: ChordEngine.fold(bufferString)) {
                commit(display + suffix, client, learned: false)
                return true
            }
        }
        // flow mode: no bar, ever — take the best word and keep moving.
        // On ambiguity, one bounded on-device LM inference (~35 ms) picks
        // with context; if the model isn't warm yet, local ranking decides.
        if MonkInputController.flowMode {
            var top = currentCandidates[0].word
            if engine.isAmbiguous(currentCandidates) {
                let words = currentCandidates.map { $0.word }
                if let ranked = MonkInputController.llm?.rerankSync(
                       context: contextWords, candidates: words),
                   let first = ranked.first {
                    top = first
                }
            }
            commit(top + suffix, client,
                   learned: ChordEngine.fold(top) != ChordEngine.fold(bufferString))
            return true
        }
        if engine.isAmbiguous(currentCandidates) && !awaitingSelection {
            awaitingSelection = true
            MonkApp.candidatesPanel?.update()
            MonkApp.candidatesPanel?.show()
            // ask the on-device LM to reorder while the user decides
            let words = currentCandidates.map { $0.word }
            MonkInputController.llm?.rerank(context: contextWords, candidates: words) {
                [weak self] ranked in
                guard let self = self, let ranked = ranked, self.awaitingSelection else { return }
                let byWord = Dictionary(uniqueKeysWithValues:
                    self.currentCandidates.map { ($0.word, $0) })
                self.currentCandidates = ranked.compactMap { byWord[$0] }
                MonkApp.candidatesPanel?.update()
            }
            return true
        }
        let top = currentCandidates[0].word
        commit(top + suffix, client,
               learned: ChordEngine.fold(top) != ChordEngine.fold(bufferString))
        return true
    }

    private func commit(_ text: String, _ client: IMKTextInput, learned: Bool,
                        applyCasing: Bool = true) {
        let hadSpace = text.hasSuffix(" ")
        let rawWord = text.trimmingCharacters(in: .whitespaces)
        let out = (applyCasing ? applyCase(rawWord) : rawWord) + (hadSpace ? " " : "")
        if learned && !keystrokes.isEmpty {
            MonkInputController.engine.learn(groups: groups, chosen: rawWord)
        }
        if !rawWord.isEmpty {
            contextWords.append(rawWord.lowercased())
            if contextWords.count > 24 { contextWords.removeFirst() }
        }
        client.insertText(out, replacementRange: NSRange(location: NSNotFound, length: 0))
        keystrokes = []
        currentCandidates = []
        awaitingSelection = false
        setMarked("", client)
        MonkApp.candidatesPanel?.hide()
    }

    private func commitRaw(_ client: IMKTextInput) {
        commit(bufferString, client, learned: false, applyCasing: false)
    }

    private func setMarked(_ s: String, _ client: IMKTextInput) {
        let attrs: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        client.setMarkedText(NSAttributedString(string: s, attributes: attrs),
                             selectionRange: NSRange(location: s.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - IMKCandidates callbacks

    override func candidates(_ sender: Any!) -> [Any]! {
        return currentCandidates.map { $0.word }
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let client = self.client() else { return }
        commit(candidateString.string + " ", client, learned: true)
    }

    override func deactivateServer(_ sender: Any!) {
        if let client = sender as? IMKTextInput, !keystrokes.isEmpty {
            commitRaw(client)
        }
        MonkApp.candidatesPanel?.hide()
    }
}
