package app.orizn.liverelay

import org.webrtc.PeerConnection
import org.webrtc.RtpParameters
import org.webrtc.RtpSender

/**
 * SDP munging and RTP tuning helpers for low-latency streaming.
 *
 * Port of `tuneOpusSdp` / `preferH264` from `WEB_RTC/static/liverelay.js` (v0.5.0).
 * Every function is best-effort: on any failure the input is returned unchanged
 * (or the call is a no-op) — tuning must never break session setup.
 */
object LatencyTuning {

    private val OPUS_RTPMAP = Regex("""a=rtpmap:(\d+) opus/48000[^\r\n]*""", RegexOption.IGNORE_CASE)
    private val MINPTIME = Regex("""(^|;)\s*minptime=""")
    private val INBAND_FEC = Regex("""(^|;)\s*useinbandfec=""")

    /**
     * Ensures `minptime=10;useinbandfec=1` on the Opus fmtp line (small audio
     * frames + in-band FEC). Appends missing params without duplicating existing
     * ones; inserts the fmtp line right after the rtpmap if absent.
     * Returns the SDP unchanged if Opus is not found or on any error.
     */
    fun tuneOpusSdp(sdp: String): String = runCatching {
        val rtpmap = OPUS_RTPMAP.find(sdp) ?: return@runCatching sdp
        val pt = rtpmap.groupValues[1]
        val fmtp = Regex("""a=fmtp:$pt ([^\r\n]*)""").find(sdp)
        if (fmtp != null) {
            var params = fmtp.groupValues[1]
            if (!MINPTIME.containsMatchIn(params)) params += ";minptime=10"
            if (!INBAND_FEC.containsMatchIn(params)) params += ";useinbandfec=1"
            sdp.replace(fmtp.value, "a=fmtp:$pt $params")
        } else {
            val newline = if (sdp.contains("\r\n")) "\r\n" else "\n"
            sdp.replace(rtpmap.value, "${rtpmap.value}${newline}a=fmtp:$pt minptime=10;useinbandfec=1")
        }
    }.getOrDefault(sdp)

    /**
     * Reorders each `m=video` line so that H264 payload types come first,
     * making H264 the preferred video codec (hardware-friendly on Android).
     * Returns the SDP unchanged if no H264 codec is present or on any error.
     */
    fun preferH264(sdp: String): String = runCatching {
        val newline = if (sdp.contains("\r\n")) "\r\n" else "\n"
        val lines = sdp.split(newline).toMutableList()
        val h264Rtpmap = Regex("""^a=rtpmap:(\d+) H264/""", RegexOption.IGNORE_CASE)

        // Pass 1: collect H264 payload types per m=video section.
        val videoSections = mutableListOf<Pair<Int, MutableList<String>>>() // m=video line index -> H264 pts
        var currentPts: MutableList<String>? = null
        for ((i, line) in lines.withIndex()) {
            if (line.startsWith("m=")) {
                currentPts = if (line.startsWith("m=video")) {
                    mutableListOf<String>().also { videoSections.add(i to it) }
                } else {
                    null
                }
            } else {
                val match = currentPts?.let { h264Rtpmap.find(line) }
                if (match != null) currentPts?.add(match.groupValues[1])
            }
        }

        // Pass 2: rewrite each m=video line with H264 payload types in front.
        var changed = false
        for ((index, h264Pts) in videoSections) {
            if (h264Pts.isEmpty()) continue
            val parts = lines[index].split(" ")
            if (parts.size <= 3) continue
            val header = parts.subList(0, 3) // "m=video", port, proto
            val payloads = parts.subList(3, parts.size)
            val reordered = payloads.filter { it in h264Pts } + payloads.filterNot { it in h264Pts }
            if (reordered != payloads) {
                lines[index] = (header + reordered).joinToString(" ")
                changed = true
            }
        }
        if (changed) lines.joinToString(newline) else sdp
    }.getOrDefault(sdp)

    /**
     * Asks the encoder to drop resolution rather than framerate under load,
     * which keeps motion smooth (lower perceived latency). Best-effort: the
     * field may be absent or read-only depending on the org.webrtc version.
     */
    fun maintainFramerate(sender: RtpSender) {
        runCatching {
            val params = sender.parameters
            params.degradationPreference = RtpParameters.DegradationPreference.MAINTAIN_FRAMERATE
            sender.parameters = params
        }
    }

    /**
     * Receiver-side jitter tuning, mirroring `tuneReceiver` in liverelay.js.
     * No-op: `jitterBufferTarget` is not exposed by the org.webrtc Java API,
     * so there is nothing safe to set here — kept for API symmetry.
     */
    fun tuneReceivers(@Suppress("UNUSED_PARAMETER") pc: PeerConnection) {
        // jitterBufferTarget is not exposed in the Java/Kotlin org.webrtc bindings — intentional no-op.
    }
}
