import Foundation

/// On-device LLM re-ranking with an embedded SmolLM2-135M (Apache-2.0),
/// running via llama.cpp compiled into this binary. No network, no API key.
///
/// When the local chord engine reports an ambiguous chord, candidates are
/// re-scored by their log-probability as the continuation of the user's
/// recent words:  score(w) = log P(w | context)  summed over w's tokens.
/// The model runs on a background queue and never blocks the keyboard;
/// results reorder the candidate bar in place if the user hasn't chosen yet.
final class LocalRanker {
    private let modelURL: URL
    private let queue = DispatchQueue(label: "com.monkkeyboard.localranker", qos: .userInitiated)
    private var model: OpaquePointer?  // llama_model *
    private var ctx: OpaquePointer?    // llama_context *
    private var vocab: OpaquePointer?  // const llama_vocab *
    private var loadAttempted = false
    /// set on `queue` after a successful load; read from the main thread as a
    /// cheap gate for the synchronous path (a stale read only delays sync
    /// re-ranking by one chord, never blocks)
    private(set) var isLoaded = false

    init?(config: [String: Any], resourceDir: URL) {
        if let enabled = config["llm"] as? Bool, !enabled { return nil }
        let url = resourceDir.appendingPathComponent("model.gguf")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        modelURL = url
    }

    deinit {
        if let ctx = ctx { llama_free(ctx) }
        if let model = model { llama_model_free(model) }
    }

    /// Must be called on `queue`.
    private func ensureLoaded() -> Bool {
        if ctx != nil { return true }
        if loadAttempted { return false }
        loadAttempted = true
        llama_backend_init()
        var mparams = llama_model_default_params()
        mparams.use_mmap = true
        guard let m = llama_model_load_from_file(modelURL.path, mparams) else {
            NSLog("Monk: failed to load %@", modelURL.path)
            return false
        }
        var cparams = llama_context_default_params()
        cparams.n_ctx = 256
        cparams.n_batch = 256
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            NSLog("Monk: failed to create llama context")
            return false
        }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        isLoaded = true
        NSLog("Monk: local LM loaded (%@)", modelURL.lastPathComponent)
        return true
    }

    /// Warm the model in the background so the first flow-mode chord
    /// can already use it.
    func preload() {
        queue.async { [weak self] in _ = self?.ensureLoaded() }
    }

    private func tokenize(_ text: String) -> [llama_token] {
        guard let vocab = vocab else { return [] }
        let utf8 = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        let n = utf8.withUnsafeBufferPointer { buf in
            llama_tokenize(vocab, buf.baseAddress, Int32(buf.count),
                           &tokens, Int32(tokens.count), true, false)
        }
        guard n >= 0 else { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    /// Sum of log P(token_i | tokens_<i) over `fullTokens[prefixLen...]`,
    /// evaluated in a single decode of the whole sequence.
    private func continuationLogProb(fullTokens: [llama_token], prefixLen: Int) -> Double? {
        guard let ctx = ctx, let vocab = vocab,
              prefixLen >= 1, fullTokens.count > prefixLen,
              fullTokens.count <= 255 else { return nil }
        llama_memory_clear(llama_get_memory(ctx), true)

        let n = fullTokens.count
        var batch = llama_batch_init(Int32(n), 0, 1)
        defer { llama_batch_free(batch) }
        batch.n_tokens = Int32(n)
        for i in 0..<n {
            batch.token[i] = fullTokens[i]
            batch.pos[i] = llama_pos(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            // need the distribution at every position that predicts a continuation token
            batch.logits[i] = (i >= prefixLen - 1 && i < n - 1) ? 1 : 0
        }
        guard llama_decode(ctx, batch) == 0 else { return nil }

        let nVocab = Int(llama_vocab_n_tokens(vocab))
        var total = 0.0
        for i in (prefixLen - 1)..<(n - 1) {
            guard let logits = llama_get_logits_ith(ctx, Int32(i)) else { return nil }
            // log softmax at the observed next token
            var maxLogit = -Float.infinity
            for v in 0..<nVocab { maxLogit = max(maxLogit, logits[v]) }
            var sumExp = 0.0
            for v in 0..<nVocab { sumExp += Double(exp(logits[v] - maxLogit)) }
            let target = Int(fullTokens[i + 1])
            total += Double(logits[target] - maxLogit) - log(sumExp)
        }
        return total
    }

    /// Core scoring. Must run on `queue` with the model loaded.
    private func scoreAll(prompt: String, candidates: [String]) -> [String]? {
        let ctxTokens = tokenize(prompt)
        guard !ctxTokens.isEmpty else { return nil }
        var scored: [(String, Double)] = []
        for cand in candidates {
            let full = tokenize(prompt + " " + cand.lowercased())
            // boundary tokenization can perturb the tail of the context;
            // score everything after the longest common prefix
            var cp = 0
            while cp < min(ctxTokens.count, full.count), full[cp] == ctxTokens[cp] { cp += 1 }
            guard cp >= 1, full.count > cp,
                  let lp = continuationLogProb(fullTokens: full, prefixLen: cp) else {
                return nil
            }
            scored.append((cand, lp))
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Reorder `candidates` by P(candidate | context). Calls back on the main
    /// queue with the new order, or nil to keep the local order.
    func rerank(context: [String], candidates: [String],
                completion: @escaping ([String]?) -> Void) {
        guard candidates.count > 1, !context.isEmpty else { completion(nil); return }
        let prompt = context.suffix(12).joined(separator: " ")
        queue.async { [weak self] in
            guard let self = self, self.ensureLoaded() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let result = self.scoreAll(prompt: prompt, candidates: candidates)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous re-rank for flow mode: bounded by one inference (~35 ms on
    /// Apple Silicon). Returns nil — without blocking — while the model is
    /// still loading (and kicks the load so the next chord can use it).
    func rerankSync(context: [String], candidates: [String]) -> [String]? {
        guard candidates.count > 1, !context.isEmpty else { return nil }
        guard isLoaded else { preload(); return nil }
        let prompt = context.suffix(12).joined(separator: " ")
        var result: [String]? = nil
        queue.sync { result = self.scoreAll(prompt: prompt, candidates: candidates) }
        return result
    }
}
