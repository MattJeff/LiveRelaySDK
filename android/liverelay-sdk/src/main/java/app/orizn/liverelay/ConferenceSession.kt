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
import java.util.concurrent.ConcurrentHashMap

/**
 * Session de conférence N-parties (équivalent Android de `ConferenceSession` dans liverelay.js).
 *
 * Architecture :
 *  - Une peer connection "publish" envoie caméra + micro via POST /sfu/conference (conferenceJoin).
 *  - Une peer connection "subscribe" recvonly PAR participant distant, créée par [subscribeTo]
 *    via POST /sfu/conference/subscribe (conferenceSubscribe + target_peer_id).
 *
 * [start] rejoint la room puis souscrit automatiquement à tous les participants déjà présents.
 * Pour les participants qui rejoignent après, appeler [subscribeTo] (peer_id obtenu via la
 * couche signalisation applicative).
 *
 * Threading : les callbacks de [LiveRelayListener] arrivent sur les threads internes WebRTC —
 * poster vers le main thread côté appelant si nécessaire (mise à jour UI).
 */
class ConferenceSession(
    private val context: Context,
    private val config: LiveRelayConfig,
    private val room: String,
) {

    var listener: LiveRelayListener? = null

    val capture: MediaCapture = MediaCapture(context)

    /** Notre peer_id dans la conférence, disponible après [start]. */
    var peerId: String? = null
        private set

    private val signaling = SignalingClient(config)

    /** Peer connection de publication (sendonly de fait). */
    private var publishPc: PeerConnection? = null

    /** Peer connections de souscription, une par participant distant (peerId -> PC). */
    private val subscribePcs = ConcurrentHashMap<String, PeerConnection>()

    @Volatile
    private var state: SessionState = SessionState.NEW

    @Volatile
    private var stopped = false

    /**
     * Rejoint la conférence : configure l'audio, démarre caméra + micro, publie via
     * conferenceJoin, puis souscrit à chaque participant déjà présent.
     */
    suspend fun start() {
        check(state == SessionState.NEW) { "ConferenceSession cannot be restarted; create a new instance" }
        PeerConnectionProvider.initialize(context)
        setState(SessionState.CONNECTING)

        try {
            AudioConfigurator.configureForCommunication(context)

            capture.startCamera()
            capture.startMicrophone()
            val videoTrack = capture.videoTrack
                ?: throw LiveRelayException("Camera capture failed to produce a video track")
            val audioTrack = capture.audioTrack
                ?: throw LiveRelayException("Microphone capture failed to produce an audio track")

            val iceServers = signaling.fetchIceServers()
            val pc = PeerConnectionProvider.makePeerConnection(iceServers, publishObserver)
            publishPc = pc

            val videoSender = pc.addTrack(videoTrack, listOf(STREAM_ID))
            pc.addTrack(audioTrack, listOf(STREAM_ID))
            LatencyTuning.maintainFramerate(videoSender)

            val offer = PeerConnectionProvider.makeTunedOffer(pc)
            val join = signaling.conferenceJoin(offer, room)
            PeerConnectionProvider.setRemoteAnswer(pc, SdpPayload(sdp = join.sdp, type = join.type))

            peerId = join.peerId
            setState(SessionState.CONNECTED)

            // Souscrit aux participants déjà présents dans la room.
            for (participant in join.participants) {
                if (participant != join.peerId) {
                    subscribeTo(participant)
                }
            }
        } catch (e: Exception) {
            setState(SessionState.FAILED)
            cleanup()
            throw e
        }
    }

    /**
     * Souscrit au flux d'un participant distant via une peer connection recvonly dédiée.
     * Idempotent : no-op si une souscription existe déjà pour ce peer_id.
     * Les tracks distants remontent au [listener] avec ce [peerId].
     */
    suspend fun subscribeTo(peerId: String) {
        if (stopped) throw LiveRelayException("Session is closed")
        if (subscribePcs.containsKey(peerId)) return

        val iceServers = signaling.fetchIceServers()
        val pc = PeerConnectionProvider.makePeerConnection(iceServers, SubscribeObserver(peerId))

        // Réserve la place avant l'échange SDP pour éviter les souscriptions concurrentes.
        val existing = subscribePcs.putIfAbsent(peerId, pc)
        if (existing != null) {
            try {
                pc.close()
            } finally {
                pc.dispose()
            }
            return
        }

        try {
            pc.addTransceiver(
                MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
                RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY)
            )
            pc.addTransceiver(
                MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO,
                RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY)
            )

            val offer = PeerConnectionProvider.makeTunedOffer(pc)
            val answer = signaling.conferenceSubscribe(offer, room, targetPeerId = peerId)
            PeerConnectionProvider.setRemoteAnswer(pc, answer)
            LatencyTuning.tuneReceivers(pc)
        } catch (e: Exception) {
            subscribePcs.remove(peerId, pc)
            try {
                pc.close()
            } finally {
                pc.dispose()
            }
            throw e
        }
    }

    /**
     * Quitte la conférence : ferme la PC de publication et toutes les PCs de souscription,
     * arrête la capture et restaure la config audio. Idempotent.
     */
    fun stop() {
        if (stopped) return
        stopped = true
        cleanup()
        setState(SessionState.CLOSED)
    }

    private fun cleanup() {
        publishPc?.let { pc ->
            try {
                pc.close()
            } finally {
                pc.dispose()
            }
        }
        publishPc = null

        for ((_, pc) in subscribePcs) {
            try {
                pc.close()
            } finally {
                pc.dispose()
            }
        }
        subscribePcs.clear()

        capture.stop()
        AudioConfigurator.reset(context)
    }

    private fun setState(newState: SessionState) {
        if (state == newState || state == SessionState.CLOSED) return
        state = newState
        listener?.onStateChanged(newState)
    }

    /** Observer de la PC de publication : pilote l'état global de la session. */
    private val publishObserver = object : BaseObserver() {
        override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) {
            if (stopped) return
            when (newState) {
                PeerConnection.IceConnectionState.CONNECTED,
                PeerConnection.IceConnectionState.COMPLETED -> setState(SessionState.CONNECTED)
                PeerConnection.IceConnectionState.DISCONNECTED -> setState(SessionState.DISCONNECTED)
                PeerConnection.IceConnectionState.FAILED -> setState(SessionState.FAILED)
                else -> Unit
            }
        }
    }

    /** Observer d'une PC de souscription : remonte les tracks distants avec le peer_id associé. */
    private inner class SubscribeObserver(private val remotePeerId: String) : BaseObserver() {
        override fun onAddTrack(receiver: RtpReceiver?, mediaStreams: Array<out MediaStream>?) {
            if (stopped) return
            when (val track = receiver?.track()) {
                is VideoTrack -> listener?.onRemoteVideoTrack(track, remotePeerId)
                is AudioTrack -> listener?.onRemoteAudioTrack(track, remotePeerId)
                else -> Unit
            }
        }
    }

    /** Observer no-op de base — le SFU n'utilise pas le trickle ICE ni les data channels. */
    private abstract class BaseObserver : PeerConnection.Observer {
        override fun onSignalingChange(newState: PeerConnection.SignalingState?) {}
        override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) {}
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState?) {}
        override fun onIceCandidate(candidate: IceCandidate?) {}
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
        override fun onAddStream(stream: MediaStream?) {}
        override fun onRemoveStream(stream: MediaStream?) {}
        override fun onDataChannel(dataChannel: DataChannel?) {}
        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(receiver: RtpReceiver?, mediaStreams: Array<out MediaStream>?) {}
    }

    private companion object {
        const val STREAM_ID = "liverelay-cam"
    }
}
