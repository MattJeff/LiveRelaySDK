import AVFoundation
import Foundation
import WebRTC

/// 1:1 bidirectional call, mirroring `liverelay.js` `call()`:
/// local camera + mic tracks added via `addTrack` (sendrecv transceivers),
/// recvonly transceivers only for kinds not being sent, H.264 preferred on
/// video send transceivers, tuned Opus offer, POST /sfu/call.
public final class CallSession {
    public weak var delegate: LiveRelaySessionDelegate?

    public var capture: MediaCapture { mediaCapture }

    private let config: LiveRelayConfig
    private let room: String
    private let signaling: SignalingClient
    private let mediaCapture: MediaCapture

    private var pc: RTCPeerConnection?
    private var pcDelegate: CallSessionPCDelegate?
    private var state: SessionState = .new

    public init(config: LiveRelayConfig, room: String) {
        self.config = config
        self.room = room
        self.signaling = SignalingClient(config: config)
        self.mediaCapture = MediaCapture(factory: PeerConnectionProvider.shared.factory)
    }

    public func start() async throws {
        guard pc == nil else { return }
        setState(.connecting)

        do {
            // 1. Audio session + local capture (camera front 1280x720@30 + mic).
            try AudioSessionConfigurator.configureForVoiceChat()
            try await mediaCapture.startCamera(position: .front, width: 1280, height: 720, fps: 30)
            mediaCapture.startMicrophone()

            // 2. ICE servers + PeerConnection.
            let iceServers = try await signaling.fetchIceServers()
            let pcDelegate = CallSessionPCDelegate(owner: self)
            self.pcDelegate = pcDelegate
            let pc = PeerConnectionProvider.shared.makePeerConnection(
                iceServers: iceServers,
                delegate: pcDelegate
            )
            self.pc = pc

            // 3. Add local tracks via addTrack — sendrecv transceivers,
            //    exactly like liverelay.js call() (pc.addTrack per track).
            let streamId = "liverelay-local"
            var sentVideo = false
            var sentAudio = false
            if let videoTrack = mediaCapture.videoTrack {
                if let sender = pc.add(videoTrack, streamIds: [streamId]) {
                    LatencyTuning.maintainFramerate(on: sender)
                    sentVideo = true
                }
            }
            if let audioTrack = mediaCapture.audioTrack {
                if pc.add(audioTrack, streamIds: [streamId]) != nil {
                    sentAudio = true
                }
            }

            // 4. Ensure we can still RECEIVE kinds we are not sending
            //    (recvonly transceivers — same fallback as liverelay.js).
            let recvOnly = RTCRtpTransceiverInit()
            recvOnly.direction = .recvOnly
            if !sentVideo {
                if let t = pc.addTransceiver(of: .video, init: recvOnly) {
                    LatencyTuning.preferH264(on: t)
                }
            }
            if !sentAudio {
                _ = pc.addTransceiver(of: .audio, init: recvOnly)
            }

            // 5. Prefer H.264 on video send transceivers (before the offer).
            for transceiver in pc.transceivers {
                if transceiver.sender.track?.kind == kRTCMediaStreamTrackKindVideo {
                    LatencyTuning.preferH264(on: transceiver)
                }
            }

            // 6. Tuned offer (Opus munging + ICE gathering wait, capped 2s).
            let offer = try await PeerConnectionProvider.shared.makeTunedOffer(for: pc)

            // 7. SDP exchange with the SFU.
            let answer = try await signaling.call(offer: offer, room: room)
            try await PeerConnectionProvider.shared.setRemoteAnswer(answer, on: pc)

            // 8. Receiver-side latency tuning (best effort).
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
        mediaCapture.stop()
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

/// Internal RTCPeerConnectionDelegate for `CallSession`.
/// Forwards `didAdd receiver` tracks and ICE connection state to the owning session.
private final class CallSessionPCDelegate: NSObject, RTCPeerConnectionDelegate {
    private weak var owner: CallSession?

    init(owner: CallSession) {
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
