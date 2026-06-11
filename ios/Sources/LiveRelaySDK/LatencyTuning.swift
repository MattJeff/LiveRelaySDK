import Foundation
import WebRTC

/// Low-latency tuning helpers, direct port of `tuneOpusSdp` / `preferH264` /
/// `tuneReceiver` from WEB_RTC/static/liverelay.js (v0.5.0).
public enum LatencyTuning {

    // MARK: - Opus SDP munging

    /// Ensures `minptime=10;useinbandfec=1` on the Opus fmtp line (small audio
    /// frames + in-band FEC). Adds the parameters without duplicating them and
    /// creates the `a=fmtp:` line right after the rtpmap line if it is absent.
    /// Returns the SDP unchanged if Opus is not found or on any regex failure.
    public static func tuneOpusSdp(_ sdp: String) -> String {
        let nsSdp = sdp as NSString
        let fullRange = NSRange(location: 0, length: nsSdp.length)

        // 1. Find the Opus rtpmap line and capture its payload type.
        guard
            let rtpmapRegex = try? NSRegularExpression(
                pattern: "a=rtpmap:(\\d+) opus/48000[^\\r\\n]*",
                options: [.caseInsensitive]
            ),
            let rtpmapMatch = rtpmapRegex.firstMatch(in: sdp, options: [], range: fullRange),
            rtpmapMatch.numberOfRanges >= 2
        else {
            return sdp
        }
        let rtpmapLine = nsSdp.substring(with: rtpmapMatch.range)
        let pt = nsSdp.substring(with: rtpmapMatch.range(at: 1))
        let escapedPt = NSRegularExpression.escapedPattern(for: pt)

        // 2. Look for the matching fmtp line.
        guard let fmtpRegex = try? NSRegularExpression(
            pattern: "a=fmtp:\(escapedPt) ([^\\r\\n]*)",
            options: []
        ) else {
            return sdp
        }

        if let fmtpMatch = fmtpRegex.firstMatch(in: sdp, options: [], range: fullRange),
           fmtpMatch.numberOfRanges >= 2 {
            // Existing fmtp line: append missing params without duplicating.
            let fmtpLine = nsSdp.substring(with: fmtpMatch.range)
            var params = nsSdp.substring(with: fmtpMatch.range(at: 1))
            if !contains(params: params, key: "minptime") {
                params += ";minptime=10"
            }
            if !contains(params: params, key: "useinbandfec") {
                params += ";useinbandfec=1"
            }
            let newLine = "a=fmtp:\(pt) \(params)"
            guard newLine != fmtpLine else { return sdp }
            return replaceFirstOccurrence(of: fmtpLine, with: newLine, in: sdp)
        }

        // 3. No fmtp line for Opus: insert one right after the rtpmap line.
        let insertion = "\(rtpmapLine)\r\na=fmtp:\(pt) minptime=10;useinbandfec=1"
        return replaceFirstOccurrence(of: rtpmapLine, with: insertion, in: sdp)
    }

    /// Mirrors the JS check `/(^|;)\s*<key>=/` on a semicolon-separated
    /// fmtp parameter string.
    private static func contains(params: String, key: String) -> Bool {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(
            pattern: "(^|;)\\s*\(escapedKey)=",
            options: []
        ) else {
            return false
        }
        let range = NSRange(location: 0, length: (params as NSString).length)
        return regex.firstMatch(in: params, options: [], range: range) != nil
    }

    /// Replaces only the first occurrence (matches JS `String.replace` with a
    /// non-global pattern, unlike Swift's `replacingOccurrences`).
    private static func replaceFirstOccurrence(
        of target: String,
        with replacement: String,
        in source: String
    ) -> String {
        guard let range = source.range(of: target) else { return source }
        return source.replacingCharacters(in: range, with: replacement)
    }

    // MARK: - Codec preferences

    /// Prefers H.264 on a video transceiver, mirroring JS `preferH264`
    /// (`RTCRtpReceiver.getCapabilities` + `setCodecPreferences`).
    ///
    /// Documented no-op: the pinned stasel/WebRTC 120.0.0 Objective-C wrapper
    /// exposes neither `setCodecPreferences:` on RTCRtpTransceiver nor
    /// `rtpReceiverCapabilitiesForKind:` on the factory (both landed in later
    /// milestones). JS guards this with
    /// `typeof transceiver.setCodecPreferences !== 'function'` and bails out —
    /// this is the Swift equivalent. Use `preferH264Sdp(_:)` on the offer SDP
    /// instead (before setLocalDescription); the default encoder factory
    /// already puts hardware H.264 first anyway.
    public static func preferH264(on transceiver: RTCRtpTransceiver) {
        guard transceiver.mediaType == .video, !transceiver.isStopped else { return }
        // Intentionally nothing else: API unavailable in WebRTC 120 ObjC.
    }

    /// SDP-munging alternative to `setCodecPreferences`: reorders H.264
    /// payload types first on every video m-line of the SDP. Apply to the
    /// offer SDP before `setLocalDescription` (same call site as
    /// `tuneOpusSdp`). Returns the SDP unchanged on any parsing failure.
    public static func preferH264Sdp(_ sdp: String) -> String {
        let nsSdp = sdp as NSString
        let fullRange = NSRange(location: 0, length: nsSdp.length)

        // Collect H.264 payload types from rtpmap lines.
        guard let rtpmapRegex = try? NSRegularExpression(
            pattern: "a=rtpmap:(\\d+) H264/90000",
            options: [.caseInsensitive]
        ) else {
            return sdp
        }
        let h264Pts = rtpmapRegex
            .matches(in: sdp, options: [], range: fullRange)
            .filter { $0.numberOfRanges >= 2 }
            .map { nsSdp.substring(with: $0.range(at: 1)) }
        guard !h264Pts.isEmpty else { return sdp }

        // Reorder the payload list of each video m-line: H.264 first.
        guard let mLineRegex = try? NSRegularExpression(
            pattern: "m=video (\\d+) ([A-Z/]+) ([0-9 ]+)",
            options: []
        ) else {
            return sdp
        }
        var result = sdp
        for match in mLineRegex.matches(in: sdp, options: [], range: fullRange).reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            let line = nsSdp.substring(with: match.range)
            let port = nsSdp.substring(with: match.range(at: 1))
            let proto = nsSdp.substring(with: match.range(at: 2))
            let pts = nsSdp.substring(with: match.range(at: 3))
                .split(separator: " ").map(String.init)
            let preferred = pts.filter { h264Pts.contains($0) }
            let others = pts.filter { !h264Pts.contains($0) }
            guard !preferred.isEmpty else { continue }
            let newLine = "m=video \(port) \(proto) \((preferred + others).joined(separator: " "))"
            result = replaceFirstOccurrence(of: line, with: newLine, in: result)
        }
        return result
    }

    // MARK: - Sender degradation preference

    /// Keeps framerate over resolution under CPU/bandwidth pressure
    /// (smoother motion → lower perceived latency for live video).
    public static func maintainFramerate(on sender: RTCRtpSender) {
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(
            value: RTCDegradationPreference.maintainFramerate.rawValue
        )
        // Reassignment is required: `parameters` is a copy property.
        sender.parameters = parameters
    }

    // MARK: - Receiver tuning

    /// JS `tuneReceiver` sets `jitterBufferTarget = 50ms` (or the legacy
    /// `playoutDelayHint`). Neither API is exposed publicly by the iOS
    /// libwebrtc Objective-C wrapper, so this is a safe best-effort no-op
    /// that keeps the call sites symmetrical with the web SDK.
    public static func tuneReceivers(of pc: RTCPeerConnection) {
        for receiver in pc.receivers {
            // No public knob to tune on RTCRtpReceiver today; iterate so the
            // hook is ready if a future binary exposes jitterBufferTarget.
            _ = receiver
        }
    }
}
