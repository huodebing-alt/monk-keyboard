import Cocoa
import InputMethodKit

@objc(CompInputController)
class CompInputController: IMKInputController {

    // one engine shared by every client (Mail, Safari, ...)
    static var engine: ChordEngine = {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        let support = CompInputController.supportDir()
        let config = CompInputController.loadConfig()
        let langs = (config["languages"] as? [String]) ?? ["en"]
        return ChordEngine(languages: langs,
                           resourceDir: resources.appendingPathComponent("dict"),
                           supportDir: support)
    }()
    static var llm: LLMRanker? = LLMRanker(config: CompInputController.loadConfig())
    static var chordWindow: TimeInterval = {
        let config = CompInputController.loadConfig()
        let ms = (config["chordWindowMs"] as? Double) ?? 45
        return ms / 1000.0
    }()

    static func supportDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Comp")
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

    private var keystrokes: [(char: Character, time: TimeInterval)] = []
    private var currentCandidates: [Candidate] = []
    private var contextWords: [String] = []
    private var awaitingSelection = false

    private var groups: [ChordGroup] {
        var out: [ChordGroup] = []
        for (i, k) in keystrokes.enumerated() {
            if i > 0 && k.time - keystrokes[i - 1].time < CompInputController.chordWindow {
                out[out.count - 1].letters.append(k.char)
            } else {
                out.append(ChordGroup(letters: [k.char]))
            }
        }
        return out
    }

    private var bufferString: String { String(keystrokes.map { $0.char }) }
    private var hasChord: Bool { groups.contains { $0.letters.count > 1 } }

    // MARK: - IMK plumbing

    override func recognizedEvents(_ sender: Any!) -> Int {
        return Int(NSEvent.EventTypeMask.keyDown.rawValue)
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
                commit(currentCandidates[0].word, client, learned: true)
            } else {
                commitRaw(client)
            }
            return true
        case 123, 124, 125, 126: // arrows
            if awaitingSelection, let panel = CompApp.candidatesPanel {
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
                commit(currentCandidates[d - 1].word, client, learned: true)
                return true
            }
        }

        if ch == " " {
            if keystrokes.isEmpty { return false }
            return commitBest(client, appendSpace: true)
        }

        let lower = Character(ch.lowercased())
        if lower.isLetter && lower.isASCII || "àâäáãåçéèêëíìîïñóòôöõúùûüÿœß".contains(lower) {
            keystrokes.append((char: lower, time: event.timestamp))
            awaitingSelection = false
            refresh(client)
            return true
        }

        // punctuation: resolve the buffer, then pass the character through
        if !keystrokes.isEmpty {
            if ",.;:!?)]}\"'".contains(ch) {
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
            CompApp.candidatesPanel?.hide()
            return
        }
        currentCandidates = CompInputController.engine.candidates(groups: groups)
        setMarked(bufferString, client)
        if !currentCandidates.isEmpty && (hasChord || currentCandidates.first!.word != bufferString) {
            CompApp.candidatesPanel?.update()
            CompApp.candidatesPanel?.show()
        } else {
            CompApp.candidatesPanel?.hide()
        }
    }

    /// Space pressed: commit the winner, or open selection if ambiguous.
    private func commitBest(_ client: IMKTextInput, appendSpace: Bool) -> Bool {
        let engine = CompInputController.engine
        guard !currentCandidates.isEmpty else {
            commit(bufferString + (appendSpace ? " " : ""), client, learned: false)
            return true
        }
        // buffer typed fully and is a real word -> identity, stay out of the way
        if engine.isWord(bufferString) && !hasChord {
            commit(bufferString + (appendSpace ? " " : ""), client, learned: false)
            return true
        }
        if engine.isAmbiguous(currentCandidates) && !awaitingSelection {
            awaitingSelection = true
            CompApp.candidatesPanel?.update()
            CompApp.candidatesPanel?.show()
            // ask the LLM (if configured) to reorder while the user decides
            let words = currentCandidates.map { $0.word }
            CompInputController.llm?.rerank(context: contextWords, candidates: words) {
                [weak self] ranked in
                guard let self = self, let ranked = ranked, self.awaitingSelection else { return }
                let byWord = Dictionary(uniqueKeysWithValues:
                    self.currentCandidates.map { ($0.word, $0) })
                self.currentCandidates = ranked.compactMap { byWord[$0] }
                CompApp.candidatesPanel?.update()
            }
            return true
        }
        commit(currentCandidates[0].word + (appendSpace ? " " : ""), client,
               learned: currentCandidates[0].word != bufferString)
        return true
    }

    private func commit(_ text: String, _ client: IMKTextInput, learned: Bool) {
        if learned && !keystrokes.isEmpty {
            CompInputController.engine.learn(groups: groups,
                                             chosen: text.trimmingCharacters(in: .whitespaces))
        }
        let word = text.trimmingCharacters(in: .whitespaces)
        if !word.isEmpty {
            contextWords.append(word)
            if contextWords.count > 24 { contextWords.removeFirst() }
        }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        keystrokes = []
        currentCandidates = []
        awaitingSelection = false
        setMarked("", client)
        CompApp.candidatesPanel?.hide()
    }

    private func commitRaw(_ client: IMKTextInput) {
        commit(bufferString, client, learned: false)
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
        CompApp.candidatesPanel?.hide()
    }
}
