import Foundation

/// Errors thrown by the LiveRelay SDK.
public enum LiveRelayError: Error {
    /// Non-2xx HTTP response from the signaling server.
    case http(status: Int, body: String)
    /// Signaling-layer failure (malformed response, transport issue, ...).
    case signaling(String)
    /// WebRTC-layer failure (SDP, ICE, PeerConnection, ...).
    case webrtc(String)
    /// Operation attempted while the session is not connected.
    case notConnected
}

extension LiveRelayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body)"
        case .signaling(let message):
            return "Signaling error: \(message)"
        case .webrtc(let message):
            return "WebRTC error: \(message)"
        case .notConnected:
            return "Session is not connected"
        }
    }
}
