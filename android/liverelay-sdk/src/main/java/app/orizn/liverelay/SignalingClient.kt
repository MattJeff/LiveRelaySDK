package app.orizn.liverelay

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * REST signaling client for the LiveRelay SFU.
 *
 * Protocol (see WEB_RTC/src/api.rs + WEB_RTC/static/liverelay.js v0.5.0):
 *  - GET  /v1/ice-servers              -> { "ice_servers": [ { urls, username?, credential? } ] }
 *  - POST /sfu/publish                 -> { sdp, type }   (body: { sdp, type, screen? })
 *  - POST /sfu/subscribe               -> { sdp, type }   (body: { sdp, type })
 *  - POST /sfu/call                    -> { sdp, type }   (body: { sdp, type })
 *  - POST /sfu/conference              -> { sdp, type, peer_id, participants }
 *  - POST /sfu/conference/subscribe    -> { sdp, type }   (body: { sdp, type, target_peer_id })
 *
 * Note: the room is encoded inside the JWT (`config.token`); the `room`
 * parameters required by the SDK contract are therefore accepted but not
 * transmitted on the wire.
 *
 * All calls run on [Dispatchers.IO]. HTTP / protocol errors are surfaced as
 * [LiveRelayException] carrying the HTTP status code when available.
 */
class SignalingClient(private val config: LiveRelayConfig) {

    private val baseUrl: String = config.baseUrl.trimEnd('/')

    /** GET /v1/ice-servers — returns STUN/TURN servers (with credentials). */
    suspend fun fetchIceServers(): List<IceServerDto> = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url("$baseUrl/v1/ice-servers")
            .get()
            .header("Authorization", "Bearer ${config.token}")
            .build()

        val body = execute(request)
        val json = parseJson(body)
        val servers = json.optJSONArray("ice_servers") ?: return@withContext emptyList()

        val result = ArrayList<IceServerDto>(servers.length())
        for (i in 0 until servers.length()) {
            val obj = servers.optJSONObject(i) ?: continue
            result.add(IceServerDto.fromJson(obj))
        }
        result
    }

    /**
     * POST /sfu/publish — send a publisher offer, receive the SFU answer.
     * [screen] = true marks this publisher as a screen share on the server.
     * [room] is part of the contract but carried by the JWT, not the body.
     */
    suspend fun publish(offer: SdpPayload, room: String, screen: Boolean): SdpPayload {
        val extra = if (screen) JSONObject().put("screen", true) else null
        return postSdp("/sfu/publish", offer, extra)
    }

    /** POST /sfu/subscribe — recvonly offer, receive the SFU answer. */
    suspend fun subscribe(offer: SdpPayload, room: String): SdpPayload =
        postSdp("/sfu/subscribe", offer, null)

    /** POST /sfu/call — 1:1 call offer (sendrecv), receive the SFU answer. */
    suspend fun call(offer: SdpPayload, room: String): SdpPayload =
        postSdp("/sfu/call", offer, null)

    /**
     * POST /sfu/conference — join an N-party conference.
     * Returns the answer plus your peer id and the participants already present.
     */
    suspend fun conferenceJoin(offer: SdpPayload, room: String): ConferenceJoinResponse =
        withContext(Dispatchers.IO) {
            val body = execute(buildSdpRequest("/sfu/conference", offer, null))
            ConferenceJoinResponse.fromJson(parseJson(body))
        }

    /**
     * POST /sfu/conference/subscribe — subscribe to a late-joining participant
     * identified by [targetPeerId] (sent as `target_peer_id`).
     */
    suspend fun conferenceSubscribe(
        offer: SdpPayload,
        room: String,
        targetPeerId: String,
    ): SdpPayload {
        val extra = JSONObject().put("target_peer_id", targetPeerId)
        return postSdp("/sfu/conference/subscribe", offer, extra)
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    private suspend fun postSdp(
        path: String,
        offer: SdpPayload,
        extraBody: JSONObject?,
    ): SdpPayload = withContext(Dispatchers.IO) {
        val body = execute(buildSdpRequest(path, offer, extraBody))
        SdpPayload.fromJson(parseJson(body))
    }

    private fun buildSdpRequest(
        path: String,
        offer: SdpPayload,
        extraBody: JSONObject?,
    ): Request {
        val json = offer.toJson()
        if (extraBody != null) {
            for (key in extraBody.keys()) {
                json.put(key, extraBody.get(key))
            }
        }
        return Request.Builder()
            .url("$baseUrl$path")
            .post(json.toString().toRequestBody(JSON_MEDIA_TYPE))
            .header("Authorization", "Bearer ${config.token}")
            .header("Content-Type", "application/json")
            .build()
    }

    /**
     * Executes [request] synchronously (caller is already on Dispatchers.IO)
     * and returns the response body as a string, or throws [LiveRelayException].
     */
    private fun execute(request: Request): String {
        val response = try {
            httpClient.newCall(request).execute()
        } catch (e: IOException) {
            throw LiveRelayException("Cannot reach server: ${e.message}", null)
        }

        response.use { resp ->
            val bodyString = try {
                resp.body?.string().orEmpty()
            } catch (e: IOException) {
                throw LiveRelayException("Failed to read response body: ${e.message}", resp.code)
            }

            if (!resp.isSuccessful) {
                throw LiveRelayException(extractErrorMessage(bodyString, resp.code), resp.code)
            }
            return bodyString
        }
    }

    /** Server errors are shaped { "error": { "code": ..., "message": ... } }. */
    private fun extractErrorMessage(body: String, statusCode: Int): String {
        return try {
            val error = JSONObject(body).optJSONObject("error")
            error?.optString("message")?.takeIf { it.isNotEmpty() }
                ?: "Server error $statusCode"
        } catch (_: Exception) {
            "Server error $statusCode"
        }
    }

    private fun parseJson(body: String): JSONObject {
        return try {
            JSONObject(body)
        } catch (e: Exception) {
            throw LiveRelayException("Invalid JSON response: ${e.message}", null)
        }
    }

    companion object {
        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()

        /** Shared OkHttp client (connection pool reused across instances), 10s timeouts. */
        private val httpClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(10, TimeUnit.SECONDS)
                .writeTimeout(10, TimeUnit.SECONDS)
                .build()
        }
    }
}
