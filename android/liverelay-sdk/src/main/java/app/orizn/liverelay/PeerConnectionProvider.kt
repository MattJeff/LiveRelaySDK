package app.orizn.liverelay

import android.content.Context
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.MediaConstraints
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.audio.JavaAudioDeviceModule

/**
 * Centralised WebRTC bootstrap: a single [PeerConnectionFactory] and a shared
 * [EglBase] context used for capture, encoding and rendering.
 *
 * Mirrors the JS SDK flow (static/liverelay.js v0.5.0):
 * createOffer -> tuneOpusSdp/preferH264 (SDP munging) -> setLocalDescription
 * -> wait for ICE gathering (capped at 2s, partial candidates are fine because
 * the SFU sits on a public IP) -> POST offer / setRemoteDescription(answer).
 *
 * Note: SdpObserver callbacks fire on internal WebRTC threads; the suspend
 * helpers below simply resume the calling coroutine from those threads.
 */
object PeerConnectionProvider {

    /** Default cap on ICE gathering, matching waitForIceGathering() in liverelay.js. */
    private const val ICE_GATHERING_TIMEOUT_MS = 2_000L
    private const val ICE_POLL_INTERVAL_MS = 50L

    private val initialized = AtomicBoolean(false)

    @Volatile
    private var appContext: Context? = null

    /** Shared EGL context for capture, hardware encode and rendering. */
    val eglBase: EglBase by lazy { EglBase.create() }

    /**
     * Shared factory. Hardware-accelerated H.264 (high profile enabled) via
     * [DefaultVideoEncoderFactory], default [JavaAudioDeviceModule] for audio.
     * Requires [initialize] to have been called first.
     */
    val factory: PeerConnectionFactory by lazy {
        val context = appContext
            ?: throw LiveRelayException("PeerConnectionProvider.initialize(context) must be called before accessing factory")
        val encoderFactory = DefaultVideoEncoderFactory(
            eglBase.eglBaseContext,
            /* enableIntelVp8Encoder = */ true,
            /* enableH264HighProfile = */ true
        )
        val decoderFactory = DefaultVideoDecoderFactory(eglBase.eglBaseContext)
        val audioDeviceModule = JavaAudioDeviceModule.builder(context)
            .createAudioDeviceModule()
        PeerConnectionFactory.builder()
            .setVideoEncoderFactory(encoderFactory)
            .setVideoDecoderFactory(decoderFactory)
            .setAudioDeviceModule(audioDeviceModule)
            .createPeerConnectionFactory()
    }

    /**
     * Loads native libraries and initialises the global WebRTC state.
     * Idempotent: subsequent calls are no-ops.
     */
    fun initialize(context: Context) {
        if (!initialized.compareAndSet(false, true)) return
        val application = context.applicationContext
        appContext = application
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(application)
                .createInitializationOptions()
        )
    }

    /**
     * Creates a [PeerConnection] configured for the LiveRelay SFU
     * (Unified Plan, continual gathering, bundled + muxed transport).
     */
    fun makePeerConnection(
        iceServers: List<IceServerDto>,
        observer: PeerConnection.Observer
    ): PeerConnection {
        val rtcIceServers = iceServers.map { dto ->
            PeerConnection.IceServer.builder(dto.urls)
                .apply {
                    dto.username?.let { setUsername(it) }
                    dto.credential?.let { setPassword(it) }
                }
                .createIceServer()
        }
        val config = PeerConnection.RTCConfiguration(rtcIceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
            iceCandidatePoolSize = 2
        }
        return factory.createPeerConnection(config, observer)
            ?: throw LiveRelayException("PeerConnectionFactory.createPeerConnection returned null")
    }

    /**
     * createOffer -> low-latency SDP munging (Opus minptime/FEC, H.264 first)
     * -> setLocalDescription -> wait for ICE gathering (capped at 2000ms;
     * resolves with partial candidates on timeout, never fails on it).
     */
    suspend fun makeTunedOffer(pc: PeerConnection): SdpPayload {
        val offer = createOffer(pc)
        val tunedSdp = LatencyTuning.preferH264(LatencyTuning.tuneOpusSdp(offer.description))
        val tunedOffer = SessionDescription(SessionDescription.Type.OFFER, tunedSdp)
        setLocalDescription(pc, tunedOffer)
        awaitIceGathering(pc, ICE_GATHERING_TIMEOUT_MS)
        val local = pc.localDescription
            ?: throw LiveRelayException("localDescription is null after setLocalDescription")
        return SdpPayload(sdp = local.description, type = "offer")
    }

    /** Applies the SFU's answer to the connection. */
    suspend fun setRemoteAnswer(pc: PeerConnection, answer: SdpPayload) {
        val description = SessionDescription(SessionDescription.Type.ANSWER, answer.sdp)
        setRemoteDescription(pc, description)
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    private suspend fun createOffer(pc: PeerConnection): SessionDescription =
        suspendCancellableCoroutine { continuation ->
            pc.createOffer(object : SdpObserver {
                override fun onCreateSuccess(description: SessionDescription?) {
                    if (description != null) {
                        continuation.resume(description)
                    } else {
                        continuation.resumeWithException(
                            LiveRelayException("createOffer returned null description")
                        )
                    }
                }

                override fun onCreateFailure(error: String?) {
                    continuation.resumeWithException(
                        LiveRelayException("createOffer failed: ${error ?: "unknown error"}")
                    )
                }

                override fun onSetSuccess() { /* not used for createOffer */ }
                override fun onSetFailure(error: String?) { /* not used for createOffer */ }
            }, MediaConstraints())
        }

    private suspend fun setLocalDescription(pc: PeerConnection, description: SessionDescription) =
        suspendCancellableCoroutine { continuation ->
            pc.setLocalDescription(object : SdpObserver {
                override fun onSetSuccess() {
                    continuation.resume(Unit)
                }

                override fun onSetFailure(error: String?) {
                    continuation.resumeWithException(
                        LiveRelayException("setLocalDescription failed: ${error ?: "unknown error"}")
                    )
                }

                override fun onCreateSuccess(sdp: SessionDescription?) { /* not used for set */ }
                override fun onCreateFailure(error: String?) { /* not used for set */ }
            }, description)
        }

    private suspend fun setRemoteDescription(pc: PeerConnection, description: SessionDescription) =
        suspendCancellableCoroutine { continuation ->
            pc.setRemoteDescription(object : SdpObserver {
                override fun onSetSuccess() {
                    continuation.resume(Unit)
                }

                override fun onSetFailure(error: String?) {
                    continuation.resumeWithException(
                        LiveRelayException("setRemoteDescription failed: ${error ?: "unknown error"}")
                    )
                }

                override fun onCreateSuccess(sdp: SessionDescription?) { /* not used for set */ }
                override fun onCreateFailure(error: String?) { /* not used for set */ }
            }, description)
        }

    /**
     * Waits until [PeerConnection.iceGatheringState] reaches COMPLETE, polling
     * lightly. On timeout it returns normally so the caller proceeds with the
     * candidates gathered so far (same semantics as the JS SDK).
     */
    private suspend fun awaitIceGathering(pc: PeerConnection, timeoutMs: Long) {
        withTimeoutOrNull(timeoutMs) {
            while (pc.iceGatheringState() != PeerConnection.IceGatheringState.COMPLETE) {
                delay(ICE_POLL_INTERVAL_MS)
            }
        }
    }
}
