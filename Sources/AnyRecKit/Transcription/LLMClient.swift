import Foundation

enum LLMClient {
    static func complete(instructions: String, text: String, using provider: SummaryProvider) async throws -> String {
        try Task.checkCancellation()
        switch provider {
        case .claude:
            return try run(provider, ["-p", instructions, "--tools", "", "--strict-mcp-config"], input: text)
        case .gemini:
            return try run(provider, ["-p", instructions], input: text)
        case .codex:
            return try runCodex(instructions + "\n\n" + text)
        case .openai:
            return try await askOpenAI(instructions, text)
        }
    }

    // Project instructions must not become context for a recording.
    private static func run(_ provider: SummaryProvider, _ arguments: [String], input: String) throws -> String {
        guard let path = provider.path else {
            throw TranscriptionError.engineFailed(
                engine: provider.rawValue, log: "\(provider.name) is not installed.")
        }
        return try inScratch { scratch in
            let result = try Shell.run(path, arguments, input: input, directory: scratch)
            guard result.succeeded else {
                throw TranscriptionError.engineFailed(
                    engine: provider.rawValue, log: String(result.combined.suffix(2_000)))
            }
            return result.standardOutput
        }
    }

    // Codex's final answer excludes its progress output.
    private static func runCodex(_ prompt: String) throws -> String {
        guard let path = SummaryProvider.codex.path else {
            throw TranscriptionError.engineFailed(engine: "codex", log: "Codex is not installed.")
        }
        return try inScratch { scratch in
            let answer = scratch.appendingPathComponent("answer.txt")
            let result = try Shell.run(
                path,
                ["exec", "--skip-git-repo-check", "-s", "read-only", "-o", answer.path, "-"],
                input: prompt, directory: scratch)
            guard result.succeeded else {
                throw TranscriptionError.engineFailed(
                    engine: "codex", log: String(result.combined.suffix(2_000)))
            }
            return (try? String(contentsOf: answer, encoding: .utf8)) ?? result.standardOutput
        }
    }

    private static func askOpenAI(_ instructions: String, _ text: String) async throws -> String {
        guard let key = OpenAIKey.current() else {
            throw TranscriptionError.engineFailed(engine: "openai", log: "There is no OpenAI key.")
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini",
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": text],
            ],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // Never include request headers in failures.
            throw TranscriptionError.engineFailed(
                engine: "openai", log: String(String(decoding: data, as: UTF8.self).suffix(1_000)))
        }
        let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choice = (reply?["choices"] as? [[String: Any]])?.first
        return (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    private static func inScratch<T>(_ body: (URL) throws -> T) throws -> T {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("anyrec-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try body(scratch)
    }
}
