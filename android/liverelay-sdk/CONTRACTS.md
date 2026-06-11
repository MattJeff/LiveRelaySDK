# liverelay-sdk Android — Contrats d'API internes (source de vérité pour tous les modules)

Module library Android (Kotlin), package `app.orizn.liverelay`, minSdk 24, target 34.
Dépendances : `io.getstream:stream-webrtc-android:1.1.1` (org.webrtc), `com.squareup.okhttp3:okhttp:4.12.0`, `org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0`, `org.json` (built-in).
Protocole signalisation : voir `WEB_RTC/static/liverelay.js` (v0.5.0) et `WEB_RTC/src/api.rs` — REST + `Authorization: Bearer <JWT>`.

Règle : chaque module implémente EXACTEMENT ces signatures publiques. Internals libres. Si le protocole réel diffère, adapter l'intérieur, jamais la signature. Fichiers dans `src/main/java/app/orizn/liverelay/`.

## Models.kt
```kotlin
data class LiveRelayConfig(val baseUrl: String, val token: String) // ex: https://sfu.kudo-ai.com
class LiveRelayException(message: String, val statusCode: Int? = null) : Exception(message)
data class SdpPayload(val sdp: String, val type: String) // "offer" | "answer"
data class IceServerDto(val urls: List<String>, val username: String?, val credential: String?)
data class ConferenceJoinResponse(val sdp: String, val type: String, val peerId: String, val participants: List<String>)
enum class SessionState { NEW, CONNECTING, CONNECTED, DISCONNECTED, FAILED, CLOSED }
interface LiveRelayListener {
    fun onStateChanged(state: SessionState)
    fun onRemoteVideoTrack(track: org.webrtc.VideoTrack, peerId: String?)
    fun onRemoteAudioTrack(track: org.webrtc.AudioTrack, peerId: String?)
}
```

## SignalingClient.kt
```kotlin
class SignalingClient(private val config: LiveRelayConfig) {
    suspend fun fetchIceServers(): List<IceServerDto>                 // GET /v1/ice-servers
    suspend fun publish(offer: SdpPayload, room: String, screen: Boolean): SdpPayload
    suspend fun subscribe(offer: SdpPayload, room: String): SdpPayload
    suspend fun call(offer: SdpPayload, room: String): SdpPayload
    suspend fun conferenceJoin(offer: SdpPayload, room: String): ConferenceJoinResponse
    suspend fun conferenceSubscribe(offer: SdpPayload, room: String, targetPeerId: String): SdpPayload
}
```
(OkHttp + org.json, withContext(Dispatchers.IO), JSON snake_case ↔ camelCase mappé à la main.)

## PeerConnectionProvider.kt
```kotlin
object PeerConnectionProvider {
    fun initialize(context: Context)           // PeerConnectionFactory.initialize, idempotent
    val eglBase: EglBase                       // partagé capture/encode/render
    val factory: PeerConnectionFactory         // DefaultVideoEncoderFactory(eglContext, true, true) hardware + enableH264HighProfile
    fun makePeerConnection(iceServers: List<IceServerDto>, observer: PeerConnection.Observer): PeerConnection
    // createOffer → LatencyTuning.tuneOpusSdp → setLocalDescription → attente ICE gathering (cap 2000ms, candidats partiels OK)
    suspend fun makeTunedOffer(pc: PeerConnection): SdpPayload
    suspend fun setRemoteAnswer(pc: PeerConnection, answer: SdpPayload)
}
```

## MediaCapture.kt + AudioConfigurator.kt
```kotlin
class MediaCapture(private val context: Context) {
    var videoTrack: org.webrtc.VideoTrack? ; private set
    var audioTrack: org.webrtc.AudioTrack? ; private set
    fun startCamera(front: Boolean = true, width: Int = 1280, height: Int = 720, fps: Int = 30)  // Camera2Capturer + SurfaceTextureHelper(eglBase)
    fun startMicrophone()  // contraintes echoCancellation/noiseSuppression/autoGainControl
    fun switchCamera()
    fun stop()
}
object AudioConfigurator {
    fun configureForCommunication(context: Context)  // AudioManager.MODE_IN_COMMUNICATION + speakerphone
    fun reset(context: Context)
}
```

## LatencyTuning.kt
```kotlin
object LatencyTuning {
    fun tuneOpusSdp(sdp: String): String                       // minptime=10;useinbandfec=1 sur fmtp opus, sans dupliquer
    fun maintainFramerate(sender: RtpSender)                   // RtpParameters.degradationPreference = MAINTAIN_FRAMERATE
    fun preferH264(sdp: String): String                        // réordonne m=video pour H264 en tête (munging, guards si absent)
    fun tuneReceivers(pc: PeerConnection)                      // best-effort, no-op safe
}
```

## Sessions (Publisher.kt / Subscriber.kt / CallSession.kt / ConferenceSession.kt)
```kotlin
class Publisher(private val context: Context, private val config: LiveRelayConfig, private val room: String) {
    var listener: LiveRelayListener? = null
    val capture: MediaCapture
    suspend fun start(screen: Boolean = false)
    fun stop()
}
class Subscriber(context: Context, config: LiveRelayConfig, room: String) {
    var listener: LiveRelayListener? = null
    suspend fun start()
    fun stop()
}
class CallSession(context: Context, config: LiveRelayConfig, room: String) {
    var listener: LiveRelayListener? = null
    val capture: MediaCapture
    suspend fun start()
    fun stop()
}
class ConferenceSession(context: Context, config: LiveRelayConfig, room: String) {
    var listener: LiveRelayListener? = null
    val capture: MediaCapture
    var peerId: String? ; private set
    suspend fun start()                          // join + subscribe aux participants existants
    suspend fun subscribeTo(peerId: String)
    fun stop()
}
```

## Rendu + Stats (LiveRelayVideoView.kt / StatsMonitor.kt)
```kotlin
class LiveRelayVideoView(context: Context, attrs: AttributeSet? = null) : SurfaceViewRenderer(context, attrs) {
    fun bind(track: org.webrtc.VideoTrack?)   // init(eglBase) idempotent + setEnableHardwareScaler(true)
    fun unbind()
}
class StatsMonitor(private val pc: PeerConnection, private val intervalMs: Long = 2000) {
    var onStats: ((LiveRelayStats) -> Unit)? = null
    fun start(); fun stop()
}
data class LiveRelayStats(val rttMs: Double?, val bitrateKbps: Double?, val packetsLost: Int?, val jitterMs: Double?, val framesPerSecond: Double?)
```

Conventions : coroutines (suspendCancellableCoroutine pour les callbacks SDP), aucun framework DI, threads WebRTC respectés (les callbacks observer arrivent sur des threads internes — poster vers le listener tel quel, documenter).
