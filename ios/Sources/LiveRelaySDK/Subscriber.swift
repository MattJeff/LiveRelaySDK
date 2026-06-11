import Foundation
import WebRTC

/// Receives a broadcast from a room (recvonly), mirroring `liverelay.js` `subscribe()`:
/// three recvonly transceivers in order — camera video, audio, screen video —
/// H.264 preferred on both video transceivers, tuned Opus offer, POST /sfu/subscribe.
public final class Subscriber {
    public weak var delegate: LiveRelaySessionDelegate?

    private let config: LiveRelayConfig
    private let room: String
    private let signaling: SignalingClient

    private var pc: RTCPeerConnection?
    private var pcDelegate: SubscriberPCDelegate?
    private var state: SessionState = .new

    public init(config: LiveRelayConfig, room: String) {
        self.config = config
        self.room = room
        self.signaling = SignalingClient(config: config)
    }

    public func start() async throws {
        guard pc == nil else { return }
        setState(.connecting)

        do {
            // 1. ICE servers from the server (TURN/STUN).
            let iceServers = try await signaling.fetchIceServers()

            // 2. PeerConnection with an internal delegate that forwards tracks/state.
            let pcDelegate = SubscriberPCDelegate(owner: self)
            self.pcDelegate = pcDelegate
            let pc = PeerConnectionProvider.shared.makePeerConnection(
                iceServers: iceServers,
                delegate: pcDelegate
            )
            self.pc = pc

            // 3. recvonly transceivers — same order as liverelay.js subscribe():
            //    camera video, audio, screen video.
            let recvOnly = RTCRtpTransceiverInit()
            recvOnly.direction = .recvOnly
            let camTransceiver = pc.addTransceiver(of: .video, init: recvOnly)
            _ = pc.addTransceiver(of: .audio, init: recvOnly)
            let screenTransceiver = pc.addTransceiver(of: .video, init: recvOnly)
            if let camTransceiver { LatencyTuning.preferH264(on: camTransceiver) }
            if let screenTransceiver { LatencyTuning.preferH264(on: screenTransceiver) }

            // 4. Tuned offer (Opus munging + ICE gathering wait, capped 2s).
            let offer = try await PeerConnectionProvider.shared.makeTunedOffer(for: pc)

            // 5. SDP exchange with the SFU.
            let answer = try await signaling.subscribe(offer: offer, room: room)
            try await PeerConnectionProvider.shared.setRemoteAnswer(answer, on: pc)

            // 6. Receiver-side latency tuning (best effort).
            LatencyTuning.tuneReceivers(of: pc)

            setState(.connected)
        } catch {
            stopInternal()
            setState(.failed)
            throw error
        }
    }

    public func stop() {
        stopInternal()
        setState(.closed)
    }

    private func stopInternal() {
        pc?.close()
        pc = nil
        pcDelegate = nil
    }

    // MARK: - Internal forwarding (called by the PC delegate)

    fileprivate func setState(_ newState: SessionState) {
        guard newState != state else { return }
        state = newState
        let delegate = self.delegate
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.session(self, didChangeState: newState)
        }
    }

    fileprivate func handleIceConnectionState(_ iceState: RTCIceConnectionState) {
        switch iceState {
        case .connected, .completed:
            setState(.connected)
        case .disconnected:
            setState(.disconnected)
        case .failed:
            setState(.failed)
        case .closed:
            setState(.disconnected)
        default:
            break
        }
    }

    fileprivate func handleReceivedTrack(_ track: RTCMediaStreamTrack) {
        let delegate = self.delegate
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let video = track as? RTCVideoTrack {
                delegate?.session(self, didReceiveVideoTrack: video, peerId: nil)
            } else if let audio = track as? RTCAudioTrack {
                delegate?.session(self, didReceiveAudioTrack: audio, peerId: nil)
            }
        }
    }
}

/// Internal RTCPeerConnectionDelegate for `Subscriber`.
/// Forwards `didAdd receiver` tracks and ICE connection state to the owning session.
private final class SubscriberPCDelegate: NSObject, RTCPeerConnectionDelegate {
    private weak var owner: Subscriber?

    init(owner: Subscriber) {
        self.owner = owner
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        owner?.handleReceivedTrack(track)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCIceConnectionState) {
        owner?.handleIceConnectionState(newState)
    }

    // Required protocol members — unused.
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
