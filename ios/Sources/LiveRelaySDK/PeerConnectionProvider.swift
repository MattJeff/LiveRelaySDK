import Foundation
import WebRTC

/// Factory + helpers for RTCPeerConnection, mirroring the web SDK flow
/// (see WEB_RTC/static/liverelay.js): createOffer → tuneOpusSdp →
/// setLocalDescription → wait for ICE gathering (cap 2s) → POST offer.
public final class PeerConnectionProvider {

    public static let shared = PeerConnectionProvider()

    /// Single SSL init for the whole process.
    private static let sslInitialized: Bool = {
        RTCInitializeSSL()
        return true
    }()

    /// Shared factory with hardware H.264 (VideoToolbox) via the default
    /// encoder/decoder factories.
    public let factory: RTCPeerConnectionFactory

    private init() {
        _ = PeerConnectionProvider.sslInitialized
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
    }

    // MARK: - Peer connection creation

    public func makePeerConnection(
        iceServers: [IceServerDTO],
        delegate: RTCPeerConnectionDelegate?
    ) -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.iceServers = iceServers.map { dto in
            if let username = dto.username, let credential = dto.credential {
                return RTCIceServer(
                    urlStrings: dto.urls,
                    username: username,
                    credential: credential
                )
            }
            return RTCIceServer(urlStrings: dto.urls)
        }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceCandidatePoolSize = 2
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        guard let pc = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: delegate
        ) else {
            // Only fails on invalid configuration, which cannot happen with
            // the hardcoded values above.
            fatalError("RTCPeerConnectionFactory failed to create a peer connection")
        }
        return pc
    }

    // MARK: - Offer / answer

    /// createOffer → LatencyTuning.tuneOpusSdp → setLocalDescription →
    /// wait for ICE gathering completion (capped at 2s, resolves with the
    /// candidates gathered so far on timeout — the SFU sits on a public IP).
    public func makeTunedOffer(for pc: RTCPeerConnection) async throws -> SdpPayload {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        // 1. createOffer
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { sdp, error in
                if let error = error {
                    continuation.resume(throwing: LiveRelayError.webrtc("createOffer failed: \(error.localizedDescription)"))
                } else if let sdp = sdp {
                    continuation.resume(returning: sdp)
                } else {
                    continuation.resume(throwing: LiveRelayError.webrtc("createOffer returned no SDP"))
                }
            }
        }

        // 2. Low-latency Opus munging.
        let tunedSdp = LatencyTuning.tuneOpusSdp(offer.sdp)
        let tunedOffer = RTCSessionDescription(type: .offer, sdp: tunedSdp)

        // 3. setLocalDescription
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(tunedOffer) { error in
                if let error = error {
                    continuation.resume(throwing: LiveRelayError.webrtc("setLocalDescription failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        // 4. Wait for ICE gathering (cap 2s, never throws on timeout).
        await waitForIceGathering(pc, timeoutSeconds: 2.0)

        // 5. Return the final local description (includes gathered candidates).
        let finalSdp = pc.localDescription?.sdp ?? tunedSdp
        return SdpPayload(sdp: finalSdp, type: "offer")
    }

    public func setRemoteAnswer(_ answer: SdpPayload, on pc: RTCPeerConnection) async throws {
        let remote = RTCSessionDescription(type: .answer, sdp: answer.sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(remote) { error in
                if let error = error {
                    continuation.resume(throwing: LiveRelayError.webrtc("setRemoteDescription failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    // MARK: - ICE gathering wait

    /// Polls `iceGatheringState` until `.complete` or the timeout elapses.
    /// Always resolves (mirrors `waitForIceGathering` in liverelay.js):
    /// partial candidates are sufficient because the SFU has a public IP.
    private func waitForIceGathering(_ pc: RTCPeerConnection, timeoutSeconds: Double) async {
        let pollIntervalNs: UInt64 = 50_000_000 // 50 ms
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while pc.iceGatheringState != .complete && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: pollIntervalNs)
            } catch {
                return // Task cancelled — proceed with what we have.
            }
        }
    }
}
