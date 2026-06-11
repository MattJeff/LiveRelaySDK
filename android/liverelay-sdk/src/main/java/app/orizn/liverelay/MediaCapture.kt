package app.orizn.liverelay

import android.content.Context
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.Camera2Capturer
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.MediaConstraints
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack

/**
 * Capture caméra (Camera2) + micro pour les sessions LiveRelay.
 *
 * Utilise [PeerConnectionProvider.eglBase] (contexte EGL partagé capture/encode/render)
 * et [PeerConnectionProvider.factory] pour créer sources et tracks.
 *
 * Résolutions standard uniquement (1280x720 / 640x480) — important pour l'encodeur hardware.
 */
class MediaCapture(private val context: Context) {

    var videoTrack: VideoTrack? = null
        private set
    var audioTrack: AudioTrack? = null
        private set

    private var videoCapturer: CameraVideoCapturer? = null
    private var surfaceTextureHelper: SurfaceTextureHelper? = null
    private var videoSource: VideoSource? = null
    private var audioSource: AudioSource? = null

    /**
     * Démarre la capture caméra et crée [videoTrack].
     * @param front caméra frontale si true, arrière sinon.
     * @param width/height/fps résolution demandée — rester sur 1280x720 ou 640x480.
     */
    fun startCamera(front: Boolean = true, width: Int = 1280, height: Int = 720, fps: Int = 30) {
        if (videoTrack != null) return // déjà démarré

        PeerConnectionProvider.initialize(context)

        val enumerator = Camera2Enumerator(context)
        val deviceName = enumerator.deviceNames.firstOrNull { name ->
            if (front) enumerator.isFrontFacing(name) else enumerator.isBackFacing(name)
        } ?: enumerator.deviceNames.firstOrNull()
        ?: throw LiveRelayException("No camera available on this device")

        val capturer = Camera2Capturer(context, deviceName, null)
        val helper = SurfaceTextureHelper.create(
            "LiveRelayCapture",
            PeerConnectionProvider.eglBase.eglBaseContext
        )
        val source = PeerConnectionProvider.factory.createVideoSource(false)

        capturer.initialize(helper, context, source.capturerObserver)
        capturer.startCapture(width, height, fps)

        videoCapturer = capturer
        surfaceTextureHelper = helper
        videoSource = source
        videoTrack = PeerConnectionProvider.factory.createVideoTrack(VIDEO_TRACK_ID, source).apply {
            setEnabled(true)
        }
    }

    /**
     * Démarre la capture micro avec traitement voix (AEC / NS / AGC) et crée [audioTrack].
     */
    fun startMicrophone() {
        if (audioTrack != null) return // déjà démarré

        PeerConnectionProvider.initialize(context)

        val constraints = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("googEchoCancellation", "true"))
            mandatory.add(MediaConstraints.KeyValuePair("googNoiseSuppression", "true"))
            mandatory.add(MediaConstraints.KeyValuePair("googAutoGainControl", "true"))
            optional.add(MediaConstraints.KeyValuePair("echoCancellation", "true"))
            optional.add(MediaConstraints.KeyValuePair("noiseSuppression", "true"))
            optional.add(MediaConstraints.KeyValuePair("autoGainControl", "true"))
        }

        val source = PeerConnectionProvider.factory.createAudioSource(constraints)
        audioSource = source
        audioTrack = PeerConnectionProvider.factory.createAudioTrack(AUDIO_TRACK_ID, source).apply {
            setEnabled(true)
        }
    }

    /**
     * Bascule front/back. No-op si la caméra n'est pas démarrée.
     */
    fun switchCamera() {
        videoCapturer?.switchCamera(null)
    }

    /**
     * Arrête la capture et libère toutes les ressources. Réutilisable après stop().
     */
    fun stop() {
        videoCapturer?.let { capturer ->
            try {
                capturer.stopCapture()
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            capturer.dispose()
        }
        videoCapturer = null

        surfaceTextureHelper?.dispose()
        surfaceTextureHelper = null

        videoTrack?.dispose()
        videoTrack = null
        videoSource?.dispose()
        videoSource = null

        audioTrack?.dispose()
        audioTrack = null
        audioSource?.dispose()
        audioSource = null
    }

    private companion object {
        const val VIDEO_TRACK_ID = "liverelay-video0"
        const val AUDIO_TRACK_ID = "liverelay-audio0"
    }
}
