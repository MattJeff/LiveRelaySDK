import Foundation

/// Configuration for connecting to a LiveRelay SFU server.
public struct LiveRelayConfig: Sendable {
    /// Base URL of the SFU, e.g. `https://sfu.kudo-ai.com`.
    public let baseURL: URL
    /// JWT used as `Authorization: Bearer <token>` on every signaling request.
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}
