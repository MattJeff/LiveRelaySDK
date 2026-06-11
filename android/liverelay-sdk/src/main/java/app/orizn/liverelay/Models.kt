package app.orizn.liverelay

import org.json.JSONArray
import org.json.JSONObject

/**
 * Configuration for the LiveRelay SDK.
 *
 * @param baseUrl Base URL of the LiveRelay SFU, e.g. `https://sfu.kudo-ai.com` (no trailing slash required).
 * @param token   JWT sent as `Authorization: Bearer <token>` on every signaling request.
 */
data class LiveRelayConfig(
    val baseUrl: String,
    val token: String,
)

/**
 * Error raised by the SDK for signaling/HTTP failures.
 *
 * @param statusCode HTTP status code when the error originates from the server, `null` otherwise.
 */
class LiveRelayException(
    message: String,
    val statusCode: Int? = null,
) : Exception(message)

/**
 * SDP offer/answer payload exchanged with the SFU.
 *
 * Wire format (snake_case-free, matches server JSON): `{"sdp": "...", "type": "offer" | "answer"}`.
 */
data class SdpPayload(
    val sdp: String,
    val type: String,
) {
    internal fun toJson(): JSONObject = JSONObject()
        .put("sdp", sdp)
        .put("type", type)

    internal companion object {
        @JvmStatic
        internal fun fromJson(json: JSONObject): SdpPayload = SdpPayload(
            sdp = json.optString("sdp", ""),
            type = json.optString("type", ""),
        )
    }
}

/**
 * One entry from `GET /v1/ice-servers` (W3C `RTCIceServer` shape).
 *
 * Server response: `{"ice_servers": [{"urls": ["stun:..."], "username": "...", "credential": "..."}]}`.
 * The server serializes `urls` as a JSON array, but the W3C dictionary also allows a single
 * string — [fromJson] accepts both.
 */
data class IceServerDto(
    val urls: List<String>,
    val username: String?,
    val credential: String?,
) {
    internal companion object {
        @JvmStatic
        internal fun fromJson(json: JSONObject): IceServerDto {
            val urls: List<String> = when (val raw = json.opt("urls")) {
                is JSONArray -> buildList {
                    for (i in 0 until raw.length()) {
                        val url = raw.optString(i, "")
                        if (url.isNotEmpty()) add(url)
                    }
                }
                is String -> listOf(raw)
                else -> emptyList()
            }
            return IceServerDto(
                urls = urls,
                username = optNullableString(json, "username"),
                credential = optNullableString(json, "credential"),
            )
        }

        private fun optNullableString(json: JSONObject, key: String): String? =
            if (json.isNull(key)) null else json.optString(key, "").takeIf { it.isNotEmpty() }
    }
}

/**
 * Response of `POST /v1/conference/{room}/join`.
 *
 * Wire format (snake_case): `{"sdp": "...", "type": "answer", "peer_id": "...", "participants": ["..."]}`.
 */
data class ConferenceJoinResponse(
    val sdp: String,
    val type: String,
    val peerId: String,
    val participants: List<String>,
) {
    internal companion object {
        @JvmStatic
        internal fun fromJson(json: JSONObject): ConferenceJoinResponse {
            val participantsJson = json.optJSONArray("participants")
            val participants: List<String> = if (participantsJson != null) {
                buildList {
                    for (i in 0 until participantsJson.length()) {
                        val id = participantsJson.optString(i, "")
                        if (id.isNotEmpty()) add(id)
                    }
                }
            } else {
                emptyList()
            }
            return ConferenceJoinResponse(
                sdp = json.optString("sdp", ""),
                type = json.optString("type", ""),
                peerId = json.optString("peer_id", ""),
                participants = participants,
            )
        }
    }
}

/** Lifecycle state of a LiveRelay session (mirrors PeerConnection state, simplified). */
enum class SessionState {
    NEW,
    CONNECTING,
    CONNECTED,
    DISCONNECTED,
    FAILED,
    CLOSED,
}

/**
 * Callbacks emitted by LiveRelay sessions.
 *
 * Note: callbacks are invoked on internal WebRTC threads — post to the main
 * thread yourself before touching UI.
 */
interface LiveRelayListener {
    fun onStateChanged(state: SessionState)
    fun onRemoteVideoTrack(track: org.webrtc.VideoTrack, peerId: String?)
    fun onRemoteAudioTrack(track: org.webrtc.AudioTrack, peerId: String?)
}
