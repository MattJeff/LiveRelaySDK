package app.orizn.liverelay

import android.content.Context
import android.util.AttributeSet
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

/**
 * Vue de rendu vidéo prête à l'emploi pour les tracks WebRTC.
 *
 * Utilisable depuis XML ou par code. `bind(track)` initialise le renderer
 * (une seule fois, idempotent) sur le contexte EGL partagé de
 * [PeerConnectionProvider], puis attache le track. `unbind()` détache le
 * track et libère les ressources EGL.
 *
 * Thread-safety : à appeler depuis le main thread (comme toute View Android).
 */
class LiveRelayVideoView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : SurfaceViewRenderer(context, attrs) {

    private var initialized = false
    private var boundTrack: VideoTrack? = null

    /**
     * Attache [track] à cette vue. Détache d'abord l'éventuel track précédent.
     * Passer `null` détache simplement le track courant.
     */
    fun bind(track: VideoTrack?) {
        ensureInitialized()
        // Détache l'ancien track s'il y en a un.
        boundTrack?.let { old ->
            try {
                old.removeSink(this)
            } catch (_: Exception) {
                // Le track a pu être disposé côté natif : ignorer.
            }
        }
        boundTrack = track
        track?.addSink(this)
    }

    /**
     * Détache le track courant et libère le renderer.
     * Safe à appeler plusieurs fois ou sans bind préalable.
     */
    fun unbind() {
        boundTrack?.let { track ->
            try {
                track.removeSink(this)
            } catch (_: Exception) {
                // Track déjà disposé : ignorer.
            }
        }
        boundTrack = null
        if (initialized) {
            initialized = false
            try {
                release()
            } catch (_: Exception) {
                // Déjà release : ignorer.
            }
        }
    }

    private fun ensureInitialized() {
        if (initialized) return
        init(PeerConnectionProvider.eglBase.eglBaseContext, null)
        setEnableHardwareScaler(true)
        initialized = true
    }
}
