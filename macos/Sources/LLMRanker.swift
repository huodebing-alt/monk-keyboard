import Foundation

/// Optional LLM re-ranking. When the local engine reports an ambiguous
/// chord, we ask Claude which candidate best continues the sentence.
/// Entirely optional: enabled only when an API key is present in
/// ~/Library/Application Support/Comp/config.json, and always async —
/// the local ranking is never blocked on the network.
final class LLMRanker {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init?(config: [String: Any]) {
        guard let key = config["apiKey"] as? String, !key.isEmpty else { return nil }
        apiKey = key
        model = (config["model"] as? String) ?? "claude-haiku-4-5-20251001"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2.0
        session = URLSession(configuration: cfg)
    }

    /// Ask the model to pick the most likely candidate given recent context.
    /// Calls back on the main queue with the reordered candidate words, or
    /// nil on any failure (caller keeps the local order).
    func rerank(context: [String], candidates: [String],
                completion: @escaping ([String]?) -> Void) {
        guard candidates.count > 1 else { completion(nil); return }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let prompt = """
        The user is typing a sentence. Recent words: "\(context.suffix(12).joined(separator: " "))"
        The next word is one of: \(candidates.joined(separator: ", ")).
        Reply with ONLY the candidates, comma-separated, most likely first.
        """
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 64,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: req) { data, _, _ in
            var result: [String]? = nil
            if let data = data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = obj["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String {
                let ranked = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                let valid = ranked.filter { candidates.map { $0.lowercased() }.contains($0) }
                if !valid.isEmpty {
                    // keep any candidates the model dropped, in original order
                    let rest = candidates.filter { !valid.contains($0.lowercased()) }
                    result = valid + rest
                }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
