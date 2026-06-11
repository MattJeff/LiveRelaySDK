import Foundation

/// REST signaling client for the LiveRelay SFU.
///
/// Mirrors the protocol implemented by `WEB_RTC/src/api.rs` / `sfu.rs`
/// and the reference JS SDK (`liverelay.js` v0.5.0):
///
/// - `GET  /v1/ice-servers`            → `{ "ice_servers": [RTCIceServer] }`
/// - `POST /sfu/publish`               → body `{ sdp, type, screen? }`, answer `{ sdp, type }`
/// - `POST /sfu/subscribe`             → body `{ sdp, type }`, answer `{ sdp, type }`
/// - `POST /sfu/call`                  → body `{ sdp, type }`, answer `{ sdp, type }`
/// - `POST /sfu/conference`            → body `{ sdp, type }`, answer `{ sdp, type, peer_id, participants }`
/// - `POST /sfu/conference/subscribe`  → body `{ sdp, type, target_peer_id }`, answer `{ sdp, type }`
///
/// The room is identified by the `room_id` claim embedded in the JWT
/// (`Authorization: Bearer <token>`); the server never reads a room field
/// from the body. The `room` parameters below are therefore accepted for
/// API-contract stability but intentionally unused.
public final class SignalingClient: Sendable {

    private let config: LiveRelayConfig
    private let session: URLSession

    /// Per-request timeout, in seconds.
    private static let requestTimeout: TimeInterval = 10

    public init(config: LiveRelayConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Public API

    /// `GET /v1/ice-servers` — fetch STUN/TURN configuration.
    public func fetchIceServers() async throws -> [IceServerDTO] {
        let data = try await performRequest(method: "GET", path: "/v1/ice-servers", body: nil)
        return try decode(IceServersResponse.self, from: data).iceServers
    }

    /// `POST /sfu/publish` — publish camera/mic (or screen) to the room in the JWT.
    public func publish(offer: SdpPayload, room: String, screen: Bool) async throws -> SdpPayload {
        // `room` lives in the JWT, not in the body — kept for signature stability.
        _ = room
        let body = PublishRequestBody(sdp: offer.sdp, type: offer.type, screen: screen ? true : nil)
        let data = try await performRequest(method: "POST", path: "/sfu/publish", body: try encode(body))
        return try decode(SdpPayload.self, from: data)
    }

    /// `POST /sfu/subscribe` — subscribe to the broadcast room in the JWT.
    public func subscribe(offer: SdpPayload, room: String) async throws -> SdpPayload {
        _ = room
        let body = SdpRequestBody(sdp: offer.sdp, type: offer.type)
        let data = try await performRequest(method: "POST", path: "/sfu/subscribe", body: try encode(body))
        return try decode(SdpPayload.self, from: data)
    }

    /// `POST /sfu/call` — join a 1:1 call room (publish + subscribe).
    public func call(offer: SdpPayload, room: String) async throws -> SdpPayload {
        _ = room
        let body = SdpRequestBody(sdp: offer.sdp, type: offer.type)
        let data = try await performRequest(method: "POST", path: "/sfu/call", body: try encode(body))
        return try decode(SdpPayload.self, from: data)
    }

    /// `POST /sfu/conference` — join an N-party conference (publish + subscribe
    /// to every participant already present).
    public func conferenceJoin(offer: SdpPayload, room: String) async throws -> ConferenceJoinResponse {
        _ = room
        let body = SdpRequestBody(sdp: offer.sdp, type: offer.type)
        let data = try await performRequest(method: "POST", path: "/sfu/conference", body: try encode(body))
        return try decode(ConferenceJoinResponse.self, from: data)
    }

    /// `POST /sfu/conference/subscribe` — subscribe to a late-joining participant.
    public func conferenceSubscribe(offer: SdpPayload, room: String, targetPeerId: String) async throws -> SdpPayload {
        _ = room
        let body = ConferenceSubscribeRequestBody(sdp: offer.sdp, type: offer.type, targetPeerId: targetPeerId)
        let data = try await performRequest(method: "POST", path: "/sfu/conference/subscribe", body: try encode(body))
        return try decode(SdpPayload.self, from: data)
    }

    // MARK: - Transport

    private func performRequest(method: String, path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveRelayError.signaling("Cannot reach server: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw LiveRelayError.signaling("Non-HTTP response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LiveRelayError.http(status: http.statusCode, body: bodyText)
        }
        return data
    }

    // MARK: - Coding helpers

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw LiveRelayError.signaling("Failed to encode request body: \(error.localizedDescription)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LiveRelayError.signaling("Failed to decode server response: \(error.localizedDescription)")
        }
    }
}

// MARK: - Private wire DTOs

/// `GET /v1/ice-servers` response wrapper: `{ "ice_servers": [...] }`.
private struct IceServersResponse: Decodable {
    let iceServers: [IceServerDTO]

    enum CodingKeys: String, CodingKey {
        case iceServers = "ice_servers"
    }
}

/// Plain SDP offer body: `{ "sdp": "...", "type": "offer" }`.
private struct SdpRequestBody: Encodable {
    let sdp: String
    let type: String
}

/// Publish body — `screen` is only serialized when true, matching the JS SDK
/// (the server's `SdpOffer.screen` is `#[serde(default)]`).
private struct PublishRequestBody: Encodable {
    let sdp: String
    let type: String
    let screen: Bool?

    enum CodingKeys: String, CodingKey {
        case sdp, type, screen
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sdp, forKey: .sdp)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(screen, forKey: .screen)
    }
}

/// Conference subscribe body: `{ "sdp", "type", "target_peer_id" }`.
private struct ConferenceSubscribeRequestBody: Encodable {
    let sdp: String
    let type: String
    let targetPeerId: String

    enum CodingKeys: String, CodingKey {
        case sdp, type
        case targetPeerId = "target_peer_id"
    }
}
