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
 * Session de réception seule (viewer) — équivalent de `LiveRelay.subscribe()` de liverelay.js.
 *
 * Flux : fetchIceServers → PeerConnection → 3 transceivers RECV_ONLY dans l'ordre
 * exact du JS (vidéo caméra, audio, vidéo écran) → offre tunée → POST /sfu/subscribe
 * → answer → tuneReceivers.
 *
 * Les callbacks de [LiveRelayListener] sont invoqués depuis les threads internes
 * WebRTC — poster vers le main thread côté appelant si nécessaire pour l'UI.
 */
class Subscriber(
    context: Context,
    private val config: LiveRelayConfig,
    private val room: String,
) {

    var listener: LiveRelayListener? = null

    private val appContext: Context = context.applicationContext
    private val signaling = SignalingClient(config)

    private var peerConnection: PeerConnection? = null

    @Volatile
    private var state: SessionState = SessionState.NEW

    /** Tracks déjà dispatchés (onTrack ET onAddTrack peuvent tirer pour le même track). */
    private val dispatchedTrackIds = HashSet<String>()

    /**
     * Démarre la souscription. Suspend jusqu'à la fin de l'échange SDP.
     * @throws LiveRelayException en cas d'erreur réseau/serveur ou si déjà démarré.
     */
    suspend fun start() {
        check(peerConnection == null) { "Subscriber already started — create a new instance" }
        PeerConnectionProvider.initialize(appContext)
        setState(SessionState.CONNECTING)

        val pc: PeerConnection
        try {
            val iceServers = signaling.fetchIceServers()
            pc = PeerConnectionProvider.makePeerConnection(iceServers, SubscriberObserver())
            peerConnection = pc
        } catch (e: Exception) {
            setState(SessionState.FAILED)
            throw e
        }

        try {
            // Même ordre que liverelay.js subscribe() :
            // 1. vidéo caméra, 2. audio, 3. vidéo écran (le serveur peut ne pas l'envoyer).
            val recvOnly = RtpTransceiver.RtpTransceiverInit(
                RtpTransceiver.RtpTransceiverDirection.RECV_ONLY
            )
            pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO, recvOnly)
            pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO, recvOnly)
            pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO, recvOnly)

            val offer = PeerConnectionProvider.makeTunedOffer(pc)
            val answer = signaling.subscribe(offer, room)
            PeerConnectionProvider.setRemoteAnswer(pc, answer)
            LatencyTuning.tuneReceivers(pc)

            setState(SessionState.CONNECTED)
        } catch (e: Exception) {
            setState(SessionState.FAILED)
            stopInternal()
            throw e
        }
    }

    /** Ferme la connexion et libère les ressources natives. État final : [SessionState.CLOSED]. */
    fun stop() {
        setState(SessionState.CLOSED)
        stopInternal()
    }

    private fun stopInternal() {
        val pc = peerConnection ?: return
        peerConnection = null
        try {
            pc.close()
        } finally {
            pc.dispose()
        }
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
    private inner class SubscriberObserver : PeerConnection.Observer {

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
}
