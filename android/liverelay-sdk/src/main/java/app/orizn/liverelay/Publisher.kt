package app.orizn.liverelay

import android.content.Context
import org.webrtc.CandidatePairChangeEvent
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.IceCandidateErrorEvent
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver

/**
 * Publishes the local camera + microphone (or screen) to a LiveRelay room
 * via POST /sfu/publish, mirroring the `LiveRelay.publish()` flow of
 * liverelay.js v0.5.0.
 *
 * Note: [LiveRelayListener] callbacks are invoked on internal WebRTC threads;
 * callers must post to their own thread/handler if needed.
 */
class Publisher(
    private val context: Context,
    private val config: LiveRelayConfig,
    private val room: String
) {
    var listener: LiveRelayListener? = null

    val capture: MediaCapture = MediaCapture(context)

    private val signaling = SignalingClient(config)

    @Volatile
    private var peerConnection: PeerConnection? = null

    @Volatile
    private var state: SessionState = SessionState.NEW

    private fun setState(next: SessionState) {
        if (state == next) return
        state = next
        listener?.onStateChanged(next)
    }

    /**
     * Internal observer: maps PeerConnection state to [SessionState] and
     * forwards it to [listener]. All other callbacks are clean no-ops
     * (a publisher neither receives remote tracks nor trickles ICE —
     * candidates are bundled into the offer by makeTunedOffer).
     */
    private val observer = object : PeerConnection.Observer {
        override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
            when (newState) {
                PeerConnection.PeerConnectionState.NEW -> Unit // keep current state
                PeerConnection.PeerConnectionState.CONNECTING -> setState(SessionState.CONNECTING)
                PeerConnection.PeerConnectionState.CONNECTED -> setState(SessionState.CONNECTED)
                PeerConnection.PeerConnectionState.DISCONNECTED -> setState(SessionState.DISCONNECTED)
                PeerConnection.PeerConnectionState.FAILED -> setState(SessionState.FAILED)
                PeerConnection.PeerConnectionState.CLOSED -> {
                    // stop() reports CLOSED itself; only relay unexpected closes.
                    if (state != SessionState.CLOSED) setState(SessionState.DISCONNECTED)
                }
            }
        }

        override fun onSignalingChange(newState: PeerConnection.SignalingState?) = Unit
        override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) = Unit
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState?) = Unit
        override fun onIceCandidate(candidate: IceCandidate?) = Unit
        override fun onIceCandidateError(event: IceCandidateErrorEvent?) = Unit
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) = Unit
        override fun onSelectedCandidatePairChanged(event: CandidatePairChangeEvent?) = Unit
        override fun onAddStream(stream: MediaStream?) = Unit
        override fun onRemoveStream(stream: MediaStream?) = Unit
        override fun onDataChannel(channel: DataChannel?) = Unit
        override fun onRenegotiationNeeded() = Unit
        override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) = Unit
        override fun onRemoveTrack(receiver: RtpReceiver?) = Unit
        override fun onTrack(transceiver: RtpTransceiver?) = Unit
    }

    /**
     * Starts publishing: configures audio, captures camera + mic, performs
     * the SDP offer/answer exchange with the SFU.
     *
     * @param screen forwarded to the server so it routes video to screen_tx.
     * @throws LiveRelayException on signaling failure.
     */
    suspend fun start(screen: Boolean = false) {
        setState(SessionState.CONNECTING)
        try {
            // 1. Audio routing for low-latency communication.
            AudioConfigurator.configureForCommunication(context)

            // 2. Local media.
            PeerConnectionProvider.initialize(context)
            capture.startCamera()
            capture.startMicrophone()
            val videoTrack = capture.videoTrack
                ?: throw LiveRelayException("Camera capture failed: no video track")
            val audioTrack = capture.audioTrack
                ?: throw LiveRelayException("Microphone capture failed: no audio track")

            // 3. PeerConnection with server-provided ICE config.
            val iceServers = signaling.fetchIceServers()
            val pc = PeerConnectionProvider.makePeerConnection(iceServers, observer)
            peerConnection = pc

            // 4. Send-only tracks, framerate kept under constraint.
            val videoSender = pc.addTrack(videoTrack, listOf("stream"))
            pc.addTrack(audioTrack, listOf("stream"))
            LatencyTuning.maintainFramerate(videoSender)

            // 5. Offer (Opus tuned + H264 preferred + ICE bundled) -> publish -> answer.
            val offer = PeerConnectionProvider.makeTunedOffer(pc)
            val answer = signaling.publish(offer, room, screen)
            PeerConnectionProvider.setRemoteAnswer(pc, answer)
        } catch (e: Exception) {
            setState(SessionState.FAILED)
            releaseResources()
            throw e
        }
    }

    /** Stops capture, closes the PeerConnection and restores audio routing. */
    fun stop() {
        releaseResources()
        setState(SessionState.CLOSED)
    }

    private fun releaseResources() {
        // Fermer la PeerConnection AVANT de disposer les tracks capturés :
        // disposer un track encore attaché à un sender actif est un usage natif invalide.
        peerConnection?.let { pc ->
            try {
                pc.close()
            } finally {
                pc.dispose()
            }
        }
        peerConnection = null
        capture.stop()
        AudioConfigurator.reset(context)
    }
}
