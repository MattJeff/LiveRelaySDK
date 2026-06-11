package app.orizn.liverelay

import android.os.Handler
import android.os.Looper
import org.webrtc.PeerConnection
import org.webrtc.RTCStatsReport

/**
 * Snapshot de métriques de qualité d'une PeerConnection.
 * Tous les champs sont nullables : `null` = donnée absente du report.
 */
data class LiveRelayStats(
    val rttMs: Double?,
    val bitrateKbps: Double?,
    val packetsLost: Int?,
    val jitterMs: Double?,
    val framesPerSecond: Double?
)

/**
 * Sonde périodique de stats WebRTC.
 *
 * Toutes les [intervalMs] millisecondes, appelle `pc.getStats` et parse le
 * [RTCStatsReport] (stats standard W3C) :
 * - `candidate-pair` active → `currentRoundTripTime` (s) → [LiveRelayStats.rttMs]
 * - `inbound-rtp` vidéo → delta `bytesReceived` → [LiveRelayStats.bitrateKbps],
 *   `packetsLost`, `jitter` (s) → [LiveRelayStats.jitterMs], `framesPerSecond`
 *
 * [onStats] est toujours invoqué sur le main thread.
 * `start()` est idempotent ; `stop()` annule la boucle.
 */
class StatsMonitor(
    private val pc: PeerConnection,
    private val intervalMs: Long = 2000
) {

    var onStats: ((LiveRelayStats) -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var running = false

    // État précédent pour les deltas de débit.
    private var prevBytesReceived: Long? = null
    private var prevTimestampUs: Double? = null

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            collect()
            mainHandler.postDelayed(this, intervalMs)
        }
    }

    /** Démarre la collecte périodique. Idempotent. */
    fun start() {
        if (running) return
        running = true
        prevBytesReceived = null
        prevTimestampUs = null
        mainHandler.post(tick)
    }

    /** Arrête la collecte. Safe à appeler plusieurs fois. */
    fun stop() {
        running = false
        mainHandler.removeCallbacks(tick)
    }

    private fun collect() {
        try {
            // Le callback getStats arrive sur un thread interne WebRTC :
            // on parse là-bas puis on poste le résultat sur le main thread.
            pc.getStats { report ->
                val stats = parseReport(report)
                mainHandler.post {
                    if (running) onStats?.invoke(stats)
                }
            }
        } catch (_: Exception) {
            // PeerConnection fermée/disposée : on arrête proprement.
            stop()
        }
    }

    private fun parseReport(report: RTCStatsReport): LiveRelayStats {
        var rttMs: Double? = null
        var bitrateKbps: Double? = null
        var packetsLost: Int? = null
        var jitterMs: Double? = null
        var framesPerSecond: Double? = null

        for (stat in report.statsMap.values) {
            val members = stat.members
            when (stat.type) {
                "candidate-pair" -> {
                    // On ne retient que la paire active (nominated + succeeded),
                    // sinon la première qui expose un RTT.
                    val state = members["state"] as? String
                    val nominated = (members["nominated"] as? Boolean) ?: false
                    val rttSeconds = (members["currentRoundTripTime"] as? Number)?.toDouble()
                    if (rttSeconds != null) {
                        if ((state == "succeeded" && nominated) || rttMs == null) {
                            rttMs = rttSeconds * 1000.0
                        }
                    }
                }
                "inbound-rtp" -> {
                    val kind = (members["kind"] as? String)
                        ?: (members["mediaType"] as? String)
                    if (kind != "video") continue

                    packetsLost = (members["packetsLost"] as? Number)?.toInt() ?: packetsLost
                    (members["jitter"] as? Number)?.toDouble()?.let { jitterMs = it * 1000.0 }
                    framesPerSecond = (members["framesPerSecond"] as? Number)?.toDouble()
                        ?: framesPerSecond

                    val bytes = (members["bytesReceived"] as? Number)?.toLong()
                    val nowUs = stat.timestampUs
                    if (bytes != null) {
                        val prevBytes = prevBytesReceived
                        val prevUs = prevTimestampUs
                        if (prevBytes != null && prevUs != null && nowUs > prevUs && bytes >= prevBytes) {
                            val deltaBits = (bytes - prevBytes) * 8.0
                            val deltaSeconds = (nowUs - prevUs) / 1_000_000.0
                            bitrateKbps = deltaBits / deltaSeconds / 1000.0
                        }
                        prevBytesReceived = bytes
                        prevTimestampUs = nowUs
                    }
                }
            }
        }

        return LiveRelayStats(
            rttMs = rttMs,
            bitrateKbps = bitrateKbps,
            packetsLost = packetsLost,
            jitterMs = jitterMs,
            framesPerSecond = framesPerSecond
        )
    }
}
