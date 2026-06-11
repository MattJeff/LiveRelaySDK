import Foundation
import WebRTC

// MARK: - SDP payload

/// SDP offer/answer exchanged with the SFU.
///
/// Server wire format (`src/sfu.rs`, `SdpOffer` / `SdpAnswer`):
/// `{ "sdp": "...", "type": "offer" | "answer" }`
/// (the Rust field `sdp_type` is renamed to `type` on the wire).
public struct SdpPayload: Codable, Sendable {
    public let sdp: String
    /// "offer" | "answer"
    public let type: String

    public init(sdp: String, type: String) {
        self.sdp = sdp
        self.type = type
    }
}

// MARK: - ICE servers

/// One entry of the `ice_servers` array returned by `GET /v1/ice-servers`.
///
/// Server wire format (`src/config.rs`, `ClientIceServer`):
/// `{ "urls": ["stun:..."], "username": "...", "credential": "..." }`
/// — `urls` is always serialized as an array by the server, and
/// `username`/`credential` are omitted when absent. Decoding also accepts a
/// single string for `urls` (W3C RTCIceServer allows both forms) for safety.
public struct IceServerDTO: Codable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    private enum CodingKeys: String, CodingKey {
        case urls, username, credential
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let array = try? container.decode([String].self, forKey: .urls) {
            self.urls = array
        } else {
            let single = try container.decode(String.self, forKey: .urls)
            self.urls = [single]
        }
        self.username = try container.decodeIfPresent(String.self, forKey: .username)
        self.credential = try container.decodeIfPresent(String.self, forKey: .credential)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(urls, forKey: .urls)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(credential, forKey: .credential)
    }
}

// MARK: - Conference

/// Response of `POST /sfu/conference` (join).
///
/// Server wire format (`src/sfu.rs`, `ConferenceAnswer`):
/// `{ "sdp": "...", "type": "answer", "participants": ["..."], "peer_id": "..." }`
public struct ConferenceJoinResponse: Decodable, Sendable {
    public let sdp: String
    public let type: String
    /// Your own peer ID (from the JWT `sub` claim). Mapped from `peer_id`.
    public let peerId: String
    /// Peer IDs of publishers already present when you joined.
    public let participants: [String]

    private enum CodingKeys: String, CodingKey {
        case sdp
        case type
        case peerId = "peer_id"
        case participants
    }
}

// MARK: - Session state

/// Lifecycle state of a LiveRelay session.
public enum SessionState: Sendable {
    case new, connecting, connected, disconnected, failed, closed
}

// MARK: - Session delegate

/// Delegate notified of session state changes and incoming media tracks.
public protocol LiveRelaySessionDelegate: AnyObject {
    func session(_ session: AnyObject, didChangeState state: SessionState)
    func session(_ session: AnyObject, didReceiveVideoTrack track: RTCVideoTrack, peerId: String?)
    func session(_ session: AnyObject, didReceiveAudioTrack track: RTCAudioTrack, peerId: String?)
}
