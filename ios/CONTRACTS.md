# LiveRelaySDK iOS — Contrats d'API internes (source de vérité pour tous les modules)

Package Swift : `LiveRelaySDK`, iOS 15+, dépendance WebRTC via SPM : `https://github.com/stasel/WebRTC.git` (binaire officiel, `import WebRTC`).
Protocole signalisation : voir `WEB_RTC/static/liverelay.js` (v0.5.0) et `WEB_RTC/src/api.rs` — REST + `Authorization: Bearer <JWT>`.

Règle : chaque module implémente EXACTEMENT ces signatures publiques. Les internals sont libres. Si le protocole réel (api.rs) diffère d'un paramètre, on adapte l'INTÉRIEUR, jamais la signature.

## Models.swift + LiveRelayConfig.swift + LiveRelayError.swift (module core)
```swift
public struct LiveRelayConfig: Sendable {
    public let baseURL: URL            // ex: https://sfu.kudo-ai.com
    public let token: String           // JWT
    public init(baseURL: URL, token: String)
}
public enum LiveRelayError: Error {
    case http(status: Int, body: String)
    case signaling(String)
    case webrtc(String)
    case notConnected
}
public struct SdpPayload: Codable, Sendable {
    public let sdp: String
    public let type: String            // "offer" | "answer"
    public init(sdp: String, type: String)
}
public struct IceServerDTO: Codable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?
}
public struct ConferenceJoinResponse: Decodable, Sendable {
    public let sdp: String
    public let type: String
    public let peerId: String          // mappé depuis peer_id
    public let participants: [String]
}
public enum SessionState: Sendable { case new, connecting, connected, disconnected, failed, closed }
public protocol LiveRelaySessionDelegate: AnyObject {
    func session(_ session: AnyObject, didChangeState state: SessionState)
    func session(_ session: AnyObject, didReceiveVideoTrack track: RTCVideoTrack, peerId: String?)
    func session(_ session: AnyObject, didReceiveAudioTrack track: RTCAudioTrack, peerId: String?)
}
```

## SignalingClient.swift
```swift
public final class SignalingClient: Sendable {
    public init(config: LiveRelayConfig)
    public func fetchIceServers() async throws -> [IceServerDTO]          // GET /v1/ice-servers
    public func publish(offer: SdpPayload, room: String, screen: Bool) async throws -> SdpPayload
    public func subscribe(offer: SdpPayload, room: String) async throws -> SdpPayload
    public func call(offer: SdpPayload, room: String) async throws -> SdpPayload
    public func conferenceJoin(offer: SdpPayload, room: String) async throws -> ConferenceJoinResponse
    public func conferenceSubscribe(offer: SdpPayload, room: String, targetPeerId: String) async throws -> SdpPayload
}
```

## PeerConnectionProvider.swift
```swift
public final class PeerConnectionProvider {
    public static let shared = PeerConnectionProvider()
    public let factory: RTCPeerConnectionFactory   // RTCDefaultVideoEncoder/DecoderFactory (H.264 hardware VideoToolbox)
    public func makePeerConnection(iceServers: [IceServerDTO], delegate: RTCPeerConnectionDelegate?) -> RTCPeerConnection
    // createOffer → LatencyTuning.tuneOpusSdp → setLocalDescription → attente ICE gathering (cap 2s, résout avec candidats partiels)
    public func makeTunedOffer(for pc: RTCPeerConnection) async throws -> SdpPayload
    public func setRemoteAnswer(_ answer: SdpPayload, on pc: RTCPeerConnection) async throws
}
```

## MediaCapture.swift + AudioSessionConfigurator.swift
```swift
public final class MediaCapture {
    public init(factory: RTCPeerConnectionFactory)
    public private(set) var videoTrack: RTCVideoTrack?
    public private(set) var audioTrack: RTCAudioTrack?
    public func startCamera(position: AVCaptureDevice.Position, width: Int, height: Int, fps: Int) async throws // défauts: .front, 1280, 720, 30
    public func startMicrophone()
    public func switchCamera() async throws
    public func stop()
}
public enum AudioSessionConfigurator {
    public static func configureForVoiceChat() throws  // .playAndRecord + .voiceChat + defaultToSpeaker + allowBluetooth
}
```

## LatencyTuning.swift
```swift
public enum LatencyTuning {
    public static func tuneOpusSdp(_ sdp: String) -> String                 // minptime=10;useinbandfec=1 sur fmtp opus, sans dupliquer
    public static func preferH264(on transceiver: RTCRtpTransceiver)        // setCodecPreferences H264 d'abord, guards
    public static func maintainFramerate(on sender: RTCRtpSender)           // degradationPreference = .maintainFramerate
    public static func tuneReceivers(of pc: RTCPeerConnection)              // best-effort (API non exposée publiquement → no-op safe)
}
```

## Sessions (Publisher.swift / Subscriber.swift / CallSession.swift / ConferenceSession.swift)
```swift
public final class Publisher {   // caméra+micro → SFU
    public weak var delegate: LiveRelaySessionDelegate?
    public init(config: LiveRelayConfig, room: String)
    public var capture: MediaCapture { get }
    public func start(screen: Bool = false) async throws
    public func stop()
}
public final class Subscriber {  // réception broadcast
    public weak var delegate: LiveRelaySessionDelegate?
    public init(config: LiveRelayConfig, room: String)
    public func start() async throws
    public func stop()
}
public final class CallSession { // 1:1 bidirectionnel
    public weak var delegate: LiveRelaySessionDelegate?
    public init(config: LiveRelayConfig, room: String)
    public var capture: MediaCapture { get }
    public func start() async throws
    public func stop()
}
public final class ConferenceSession { // N-parties
    public weak var delegate: LiveRelaySessionDelegate?
    public init(config: LiveRelayConfig, room: String)
    public var capture: MediaCapture { get }
    public private(set) var peerId: String?
    public func start() async throws                      // join + subscribe à chaque participant existant
    public func subscribeTo(peerId: String) async throws
    public func stop()
}
```

## Rendu + Stats (VideoRenderView.swift / StatsMonitor.swift)
```swift
public struct LiveRelayVideoView: UIViewRepresentable {   // SwiftUI, wrap RTCMTLVideoView
    public init(track: RTCVideoTrack?)
}
public final class StatsMonitor {
    public init(pc: RTCPeerConnection, intervalSeconds: Double = 2.0)
    public var onStats: ((LiveRelayStats) -> Void)?
    public func start(); public func stop()
}
public struct LiveRelayStats: Sendable {
    public let rttMs: Double?
    public let bitrateKbps: Double?
    public let packetsLost: Int?
    public let jitterMs: Double?
    public let framesPerSecond: Double?
}
```

Conventions : async/await, pas de dépendance autre que WebRTC, @MainActor uniquement où nécessaire (UI), tout le reste thread-safe. Tous les fichiers dans `Sources/LiveRelaySDK/`.
