import Foundation
import AVFoundation
import WebRTC

/// Publishes the local camera + microphone (or screen) to the LiveRelay SFU.
///
/// Mirrors the reference web flow (`liverelay.js` → `LiveRelay.publish`):
/// capture → ICE servers → PeerConnection → addTrack → tuned offer →
/// POST /sfu/publish → set remote answer.
public final class Publisher {

    // MARK: - Public API (contract)

    public weak var delegate: LiveRelaySessionDelegate?

    public var capture: MediaCapture { _capture }

    public init(config: LiveRelayConfig, room: String) {
        self.room = room
        self.signaling = SignalingClient(config: config)
        self._capture = MediaCapture(factory: PeerConnectionProvider.shared.factory)
    }

    public func start(screen: Bool = false) async throws {
        notify(.connecting)
        do {
            // 1. Audio session for voice chat (speaker + bluetooth).
            try AudioSessionConfigurator.configureForVoiceChat()

            // 2. Local media (defaults: front camera, 1280x720@30 + mic).
            try await _capture.startCamera(position: .front, width: 1280, height: 720, fps: 30)
            _capture.startMicrophone()

            // 3. ICE servers + PeerConnection with internal state delegate.
            let iceServers = try await signaling.fetchIceServers()
            let pcDelegate = PCDelegate(owner: self)
            self.pcDelegate = pcDelegate
            let pc = PeerConnectionProvider.shared.makePeerConnection(
                iceServers: iceServers,
                delegate: pcDelegate
            )
            self.pc = pc

            // 4. Add tracks, then tune for low latency (before createOffer).
            if let videoTrack = _capture.videoTrack {
                let sender = pc.add(videoTrack, streamIds: ["stream"])
                if let videoTransceiver = pc.transceivers.first(where: { $0.mediaType == .video }) {
                    LatencyTuning.preferH264(on: videoTransceiver)
                }
                if let sender {
                    LatencyTuning.maintainFramerate(on: sender)
                }
            }
            if let audioTrack = _capture.audioTrack {
                _ = pc.add(audioTrack, streamIds: ["stream"])
            }

            // 5. Tuned offer → publish → remote answer.
            let offer = try await PeerConnectionProvider.shared.makeTunedOffer(for: pc)
            let answer = try await signaling.publish(offer: offer, room: room, screen: screen)
            try await PeerConnectionProvider.shared.setRemoteAnswer(answer, on: pc)
        } catch {
            teardown()
            notify(.failed)
            throw error
        }
    }

    public func stop() {
        teardown()
        notify(.closed)
    }

    // MARK: - Internals

    private let room: String
    private let signaling: SignalingClient
    private let _capture: MediaCapture
    private var pc: RTCPeerConnection?
    private var pcDelegate: PCDelegate?

    private let stateLock = NSLock()
    private var lastState: SessionState = .new

    private func teardown() {
        _capture.stop()
        pcDelegate?.invalidate()
        pcDelegate = nil
        pc?.close()
        pc = nil
    }

    /// Forwards a state change to the session delegate (deduplicated, on main).
    fileprivate func notify(_ state: SessionState) {
        stateLock.lock()
        guard state != lastState else {
            stateLock.unlock()
            return
        }
        lastState = state
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.session(self, didChangeState: state)
        }
    }

    // MARK: - PeerConnection delegate

    /// Internal RTCPeerConnectionDelegate: maps connection states to
    /// `SessionState` and forwards them to the owning Publisher.
    private final class PCDelegate: NSObject, RTCPeerConnectionDelegate {

        private weak var owner: Publisher?

        init(owner: Publisher) {
            self.owner = owner
            super.init()
        }

        func invalidate() {
            owner = nil
        }

        // Unified connection state — the primary source for SessionState.
        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didChange newState: RTCPeerConnectionState) {
            let mapped: SessionState
            switch newState {
            case .new: mapped = .new
            case .connecting: mapped = .connecting
            case .connected: mapped = .connected
            case .disconnected: mapped = .disconnected
            case .failed: mapped = .failed
            case .closed: mapped = .closed
            @unknown default: mapped = .disconnected
            }
            owner?.notify(mapped)
        }

        // Required delegate methods (publisher sends only — mostly no-ops).
        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didChange stateChanged: RTCSignalingState) {}

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didAdd stream: RTCMediaStream) {}

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didRemove stream: RTCMediaStream) {}

        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didChange newState: RTCIceConnectionState) {}

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didChange newState: RTCIceGatheringState) {}

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didGenerate candidate: RTCIceCandidate) {
            // ICE candidates are gathered inline by makeTunedOffer (no trickle).
        }

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didRemove candidates: [RTCIceCandidate]) {}

        func peerConnection(_ peerConnection: RTCPeerConnection,
                            didOpen dataChannel: RTCDataChannel) {}
    }
}
