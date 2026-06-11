import Foundation
import WebRTC

/// Session de conférence N-parties LiveRelay.
///
/// Flux (miroir de `ConferenceSession` / `subscribeToParticipant` de liverelay.js) :
/// - `start()` : audio session → capture caméra+micro → PC principale (publish)
///   → offre tunée → `POST /sfu/conference` → answer + `peer_id` + `participants`
///   → une PC recvonly par participant déjà présent via `subscribeTo(peerId:)`.
/// - `subscribeTo(peerId:)` : PC dédiée recvonly (video+audio, H.264 préféré)
///   → `POST /sfu/conference/subscribe` avec `target_peer_id`.
/// - Les tracks distantes remontent via `LiveRelaySessionDelegate` avec le
///   `peerId` du participant correspondant.
public final class ConferenceSession {

    public weak var delegate: LiveRelaySessionDelegate?

    /// Capture locale (caméra + micro) publiée dans la conférence.
    public var capture: MediaCapture { mediaCapture }

    /// Notre peer_id dans la conférence (disponible après `start()`).
    public private(set) var peerId: String?

    // MARK: - Privé

    private let config: LiveRelayConfig
    private let room: String
    private let signaling: SignalingClient
    private let provider = PeerConnectionProvider.shared
    private let mediaCapture: MediaCapture

    private let lock = NSLock()
    private var publishPC: RTCPeerConnection?
    private var subscribePCs: [String: RTCPeerConnection] = [:]
    /// `RTCPeerConnection.delegate` est weak : on retient les observers ici.
    private var observers: [PeerConnectionObserver] = []
    private var state: SessionState = .new

    public init(config: LiveRelayConfig, room: String) {
        self.config = config
        self.room = room
        self.signaling = SignalingClient(config: config)
        self.mediaCapture = MediaCapture(factory: PeerConnectionProvider.shared.factory)
    }

    deinit {
        stop()
    }

    // MARK: - Start

    /// Rejoint la conférence : publie caméra+micro puis s'abonne à chaque
    /// participant déjà présent.
    public func start() async throws {
        setState(.connecting)
        do {
            // 1. Audio session + capture locale.
            try AudioSessionConfigurator.configureForVoiceChat()
            try await mediaCapture.startCamera()
            mediaCapture.startMicrophone()

            // 2. Peer connection de publication.
            let iceServers = try await signaling.fetchIceServers()
            let observer = PeerConnectionObserver()
            let pc = provider.makePeerConnection(iceServers: iceServers, delegate: observer)

            observer.onIceConnectionStateChange = { [weak self] iceState in
                self?.handlePublishIceState(iceState)
            }
            // La PC principale peut aussi recevoir des tracks (participants
            // présents au join, stream id "lr-XXXXXXXX" côté serveur).
            observer.onTrack = { [weak self] receiver, streams in
                let remotePeerId = streams.first?.streamId
                self?.deliverTrack(from: receiver, peerId: remotePeerId)
            }

            lock.lock()
            publishPC = pc
            observers.append(observer)
            lock.unlock()

            // 3. Tracks locales + tuning encodeur (avant createOffer).
            if let videoTrack = mediaCapture.videoTrack,
               let sender = pc.add(videoTrack, streamIds: ["liverelay-cam"]) {
                LatencyTuning.maintainFramerate(on: sender)
            }
            if let audioTrack = mediaCapture.audioTrack {
                _ = pc.add(audioTrack, streamIds: ["liverelay-cam"])
            }
            for transceiver in pc.transceivers where transceiver.mediaType == .video {
                LatencyTuning.preferH264(on: transceiver)
            }

            // 4. Offre tunée → conference join → answer.
            let offer = try await provider.makeTunedOffer(for: pc)
            let response = try await signaling.conferenceJoin(offer: offer, room: room)
            try await provider.setRemoteAnswer(
                SdpPayload(sdp: response.sdp, type: response.type),
                on: pc
            )
            LatencyTuning.tuneReceivers(of: pc)

            lock.lock()
            peerId = response.peerId
            lock.unlock()

            setState(.connected)

            // 5. Une PC recvonly par participant déjà présent.
            //    Best-effort : l'échec d'un abonnement ne casse pas la conférence.
            for participant in response.participants where participant != response.peerId {
                do {
                    try await subscribeTo(peerId: participant)
                } catch {
                    #if DEBUG
                    print("[LiveRelay] conference: subscribe to \(participant) failed: \(error)")
                    #endif
                }
            }
        } catch {
            setState(.failed)
            teardown()
            throw error
        }
    }

    // MARK: - Subscribe

    /// S'abonne à un participant (présent au join, ou arrivé après nous).
    public func subscribeTo(peerId targetPeerId: String) async throws {
        lock.lock()
        let alreadySubscribed = subscribePCs[targetPeerId] != nil
        let closed = state == .closed
        lock.unlock()
        guard !alreadySubscribed else { return }
        guard !closed else { throw LiveRelayError.notConnected }

        let iceServers = try await signaling.fetchIceServers()
        let observer = PeerConnectionObserver()
        let pc = provider.makePeerConnection(iceServers: iceServers, delegate: observer)

        observer.onTrack = { [weak self] receiver, _ in
            self?.deliverTrack(from: receiver, peerId: targetPeerId)
        }

        lock.lock()
        subscribePCs[targetPeerId] = pc
        observers.append(observer)
        lock.unlock()

        do {
            // Transceivers recvonly video + audio (H.264 préféré avant l'offre).
            let recvOnly = RTCRtpTransceiverInit()
            recvOnly.direction = .recvOnly
            if let videoTransceiver = pc.addTransceiver(of: .video, init: recvOnly) {
                LatencyTuning.preferH264(on: videoTransceiver)
            }
            _ = pc.addTransceiver(of: .audio, init: recvOnly)

            let offer = try await provider.makeTunedOffer(for: pc)
            let answer = try await signaling.conferenceSubscribe(
                offer: offer,
                room: room,
                targetPeerId: targetPeerId
            )
            try await provider.setRemoteAnswer(answer, on: pc)
            LatencyTuning.tuneReceivers(of: pc)
        } catch {
            lock.lock()
            subscribePCs[targetPeerId] = nil
            lock.unlock()
            pc.close()
            throw error
        }
    }

    // MARK: - Stop

    /// Quitte la conférence : ferme la PC de publication, toutes les PCs
    /// d'abonnement et arrête la capture locale.
    public func stop() {
        lock.lock()
        let alreadyClosed = state == .closed
        lock.unlock()
        guard !alreadyClosed else { return }

        teardown()
        setState(.closed)
    }

    // MARK: - Internals

    private func teardown() {
        lock.lock()
        let publish = publishPC
        let subs = subscribePCs
        publishPC = nil
        subscribePCs.removeAll()
        observers.removeAll()
        lock.unlock()

        for (_, pc) in subs { pc.close() }
        publish?.close()
        mediaCapture.stop()
    }

    private func setState(_ newState: SessionState) {
        lock.lock()
        guard state != newState else {
            lock.unlock()
            return
        }
        state = newState
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.session(self, didChangeState: newState)
        }
    }

    private func handlePublishIceState(_ iceState: RTCIceConnectionState) {
        lock.lock()
        let closed = state == .closed
        lock.unlock()
        guard !closed else { return }

        switch iceState {
        case .connected, .completed:
            setState(.connected)
        case .disconnected:
            setState(.disconnected)
        case .failed:
            setState(.failed)
        default:
            break
        }
    }

    private func deliverTrack(from receiver: RTCRtpReceiver, peerId remotePeerId: String?) {
        guard let track = receiver.track else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let video = track as? RTCVideoTrack {
                self.delegate?.session(self, didReceiveVideoTrack: video, peerId: remotePeerId)
            } else if let audio = track as? RTCAudioTrack {
                self.delegate?.session(self, didReceiveAudioTrack: audio, peerId: remotePeerId)
            }
        }
    }
}

// MARK: - PeerConnectionObserver

/// Adaptateur `RTCPeerConnectionDelegate` → closures.
/// `RTCPeerConnection` ne retient pas son delegate : la session le garde en vie.
private final class PeerConnectionObserver: NSObject, RTCPeerConnectionDelegate {

    var onTrack: ((RTCRtpReceiver, [RTCMediaStream]) -> Void)?
    var onIceConnectionStateChange: ((RTCIceConnectionState) -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        onTrack?(rtpReceiver, mediaStreams)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        onIceConnectionStateChange?(newState)
    }

    // MARK: Méthodes requises restantes (no-op)

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
