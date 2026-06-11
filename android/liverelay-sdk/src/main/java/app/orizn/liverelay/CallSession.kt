package app.orizn.liverelay

import android.content.Context
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.VideoTrack

/**
 * Appel 1:1 (publish + subscribe sur la même PeerConnection) — équivalent de
 * `LiveRelay.call()` de liverelay.js.
 *
 * Flux : mode audio communication → capture caméra+micro → fetchIceServers →
 * PeerConnection → addTrack (sendrecv, comme le JS qui a toujours vidéo+audio
 * locaux donc aucun transceiver recvonly additionnel) → offre tunée →
 * POST /sfu/call → answer → tuneReceivers + maintainFramerate sur le sender vidéo.
 *
 * Les callbacks de [LiveRelayListener] arrivent depuis les threads internes
 * WebRTC — poster vers le main thread côté appelant si nécessaire pour l'UI.
 */
class CallSession(
    context: Context,
    private val config: LiveRelayConfig,
    private val room: String,
) {

    var listener: LiveRelayListener? = null

    private val appContext: Context = context.applicationContext
    private val signaling = SignalingClient(config)

    val capture: MediaCapture = MediaCapture(appContext)

    private var peerConnection: PeerConnection? = null

    @Volatile
    private var state: SessionState = SessionState.NEW

    /** Tracks distants déjà dispatchés (onTrack ET onAddTrack peuvent tirer pour le même track). */
    private val dispatchedTrackIds = HashSet<String>()

    /**
     * Démarre l'appel. Suspend jusqu'à la fin de l'échange SDP.
     * @throws LiveRelayException en cas d'erreur réseau/serveur ou si déjà démarré.
     */
    suspend fun start() {
        check(peerConnection == null) { "CallSession already started — create a new instance" }
        PeerConnectionProvider.initialize(appContext)
        setState(SessionState.CONNECTING)

        try {
            AudioConfigurator.configureForCommunication(appContext)
            capture.startCamera()
            capture.startMicrophone()
            val localVideo = capture.videoTrack
                ?: throw LiveRelayException("Camera capture failed to produce a video track")
            val localAudio = capture.audioTrack
                ?: throw LiveRelayException("Microphone capture failed to produce an audio track")

            val iceServers = signaling.fetchIceServers()
            val pc = PeerConnectionProvider.makePeerConnection(iceServers, CallObserver())
            peerConnection = pc

            // Comme liverelay.js call() : addTrack ⇒ transceivers sendrecv.
            // Vidéo et audio locaux sont toujours présents ⇒ aucun recvonly additionnel.
            val streamIds = listOf(LOCAL_STREAM_ID)
            val videoSender = pc.addTrack(localVideo, streamIds)
            pc.addTrack(localAudio, streamIds)
            LatencyTuning.maintainFramerate(videoSender)

            val offer = PeerConnectionProvider.makeTunedOffer(pc)
            val answer = signaling.call(offer, room)
            PeerConnectionProvider.setRemoteAnswer(pc, answer)
            LatencyTuning.tuneReceivers(pc)
            LatencyTuning.maintainFramerate(videoSender) // ré-applique après négociation

            setState(SessionState.CONNECTED)
        } catch (e: Exception) {
            setState(SessionState.FAILED)
            cleanup()
            throw e
        }
    }

    /**
     * Termine l'appel : ferme la PeerConnection, stoppe la capture, restaure
     * le mode audio. État final : [SessionState.CLOSED].
     */
    fun stop() {
        setState(SessionState.CLOSED)
        cleanup()
    }

    private fun cleanup() {
        peerConnection?.let { pc ->
            peerConnection = null
            try {
                pc.close()
            } finally {
                pc.dispose()
            }
        }
        capture.stop()
        AudioConfigurator.reset(appContext)
        synchronized(dispatchedTrackIds) { dispatchedTrackIds.clear() }
    }

    private fun setState(next: SessionState) {
        synchronized(this) {
            if (state == SessionState.CLOSED || state == next) return
            state = next
        }
        listener?.onStateChanged(next)
    }

    private fun dispatchRemoteTrack(track: MediaStreamTrack?) {
        if (track == null || state == SessionState.CLOSED) return
        val alreadySeen = synchronized(dispatchedTrackIds) { !dispatchedTrackIds.add(track.id()) }
        if (alreadySeen) return
        when (track) {
            is VideoTrack -> listener?.onRemoteVideoTrack(track, null)
            is AudioTrack -> listener?.onRemoteAudioTrack(track, null)
        }
    }

    /** Observer WebRTC — callbacks sur threads internes, relayés tels quels. */
    private inner class CallObserver : PeerConnection.Observer {

        override fun onTrack(transceiver: RtpTransceiver?) {
            dispatchRemoteTrack(transceiver?.receiver?.track())
        }

        override fun onAddTrack(receiver: RtpReceiver?, mediaStreams: Array<out MediaStream>?) {
            dispatchRemoteTrack(receiver?.track())
        }

        override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) {
            when (newState) {
                PeerConnection.IceConnectionState.CONNECTED,
                PeerConnection.IceConnectionState.COMPLETED -> setState(SessionState.CONNECTED)
                PeerConnection.IceConnectionState.DISCONNECTED -> setState(SessionState.DISCONNECTED)
                PeerConnection.IceConnectionState.FAILED -> setState(SessionState.FAILED)
                else -> Unit // NEW / CHECKING / CLOSED : gérés par start()/stop()
            }
        }

        override fun onSignalingChange(newState: PeerConnection.SignalingState?) = Unit
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState?) = Unit
        override fun onIceCandidate(candidate: IceCandidate?) = Unit
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) = Unit
        override fun onAddStream(stream: MediaStream?) = Unit
        override fun onRemoveStream(stream: MediaStream?) = Unit
        override fun onDataChannel(dataChannel: DataChannel?) = Unit
        override fun onRenegotiationNeeded() = Unit
    }

    private companion object {
        const val LOCAL_STREAM_ID = "liverelay-android-call"
    }
}
