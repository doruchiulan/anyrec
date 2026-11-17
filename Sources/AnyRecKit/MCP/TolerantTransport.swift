import Foundation
import Logging
import MCP

/// Stdio, with the client's capabilities taken out of `initialize` before the SDK reads it.
///
/// swift-sdk 0.12.1 types `capabilities.experimental` as `[String: String]`; the spec makes
/// each value an object. The ChatGPT app's Codex sends `{"codex/auth-change": {}}`, so the
/// SDK refused its handshake ("The data couldn't be read because it isn't in the correct
/// format") and ChatGPT never saw the tools (swift-sdk issues 262 and 287, unreleased fix in
/// PR 276). The server asks nothing of the client, so the capabilities are dropped whole.
/// Remove this once a release decodes them.
actor TolerantTransport: Transport {
    private let inner: StdioTransport
    nonisolated let logger: Logger

    init(_ inner: StdioTransport = StdioTransport()) {
        self.inner = inner
        logger = inner.logger
    }

    func connect() async throws { try await inner.connect() }
    func disconnect() async { await inner.disconnect() }
    func send(_ data: Data) async throws { try await inner.send(data) }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let inner = inner
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in await inner.receive() { continuation.yield(Self.tolerant(message)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `message` unchanged, unless it is `initialize`: then with empty capabilities.
    static func tolerant(_ message: Data) -> Data {
        guard message.range(of: Data("\"initialize\"".utf8)) != nil,
              var request = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              request["method"] as? String == "initialize",
              var params = request["params"] as? [String: Any]
        else { return message }
        params["capabilities"] = [String: Any]()
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? message
    }
}
