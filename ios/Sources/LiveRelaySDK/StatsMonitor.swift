import Foundation
import WebRTC

/// Snapshot of connection quality metrics, emitted periodically by `StatsMonitor`.
public struct LiveRelayStats: Sendable {
    /// Round-trip time of the active ICE candidate pair, in milliseconds.
    public let rttMs: Double?
    /// Incoming video bitrate (delta of bytesReceived between two polls), in kbit/s.
    public let bitrateKbps: Double?
    /// Cumulative packets lost on inbound video RTP streams.
    public let packetsLost: Int?
    /// Inbound video jitter, in milliseconds.
    public let jitterMs: Double?
    /// Decoded frames per second of the inbound video stream.
    public let framesPerSecond: Double?

    public init(rttMs: Double?,
                bitrateKbps: Double?,
                packetsLost: Int?,
                jitterMs: Double?,
                framesPerSecond: Double?) {
        self.rttMs = rttMs
        self.bitrateKbps = bitrateKbps
        self.packetsLost = packetsLost
        self.jitterMs = jitterMs
        self.framesPerSecond = framesPerSecond
    }
}

/// Polls `RTCPeerConnection.statistics` on a fixed interval and emits parsed
/// `LiveRelayStats`. `start()` is idempotent; `stop()` invalidates the timer.
/// `onStats` is always invoked on the main queue.
public final class StatsMonitor {
    private let pc: RTCPeerConnection
    private let intervalSeconds: Double

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var running = false

    // Previous-poll state, used to compute deltas (bitrate).
    private var previousBytesReceived: Double?
    private var previousTimestampUs: Double?

    /// Called on the main queue every `intervalSeconds` with fresh stats.
    public var onStats: ((LiveRelayStats) -> Void)?

    public init(pc: RTCPeerConnection, intervalSeconds: Double = 2.0) {
        self.pc = pc
        self.intervalSeconds = intervalSeconds
    }

    deinit {
        stop()
    }

    /// Starts periodic polling. Calling `start()` while already running is a no-op.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        running = true

        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.liverelay.statsmonitor"))
        source.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            self?.collect()
        }
        source.resume()
        timer = source
    }

    /// Stops polling and resets delta state. Safe to call multiple times.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        running = false
        timer?.cancel()
        timer = nil
        previousBytesReceived = nil
        previousTimestampUs = nil
    }

    // MARK: - Collection

    private func collect() {
        pc.statistics { [weak self] report in
            self?.process(report)
        }
    }

    private func process(_ report: RTCStatisticsReport) {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }

        var rttMs: Double?
        var selectedPairFound = false
        var bytesReceived: Double = 0
        var hasInboundVideo = false
        var packetsLost: Int?
        var jitterMs: Double?
        var framesPerSecond: Double?

        for stat in report.statistics.values {
            switch stat.type {
            case "candidate-pair":
                let values = stat.values
                let nominated = (values["nominated"] as? NSNumber)?.boolValue ?? false
                let succeeded = (values["state"] as? String) == "succeeded"
                let isActive = nominated && succeeded
                // Prefer the nominated+succeeded pair; otherwise fall back to
                // any pair exposing an RTT.
                if let rtt = (values["currentRoundTripTime"] as? NSNumber)?.doubleValue,
                   isActive || (!selectedPairFound && rttMs == nil) {
                    rttMs = rtt * 1000.0
                    if isActive { selectedPairFound = true }
                }

            case "inbound-rtp":
                let values = stat.values
                let kind = (values["kind"] as? String) ?? (values["mediaType"] as? String)
                guard kind == "video" else { continue }
                hasInboundVideo = true
                if let bytes = (values["bytesReceived"] as? NSNumber)?.doubleValue {
                    bytesReceived += bytes
                }
                if let lost = (values["packetsLost"] as? NSNumber)?.intValue {
                    packetsLost = (packetsLost ?? 0) + lost
                }
                if let jitter = (values["jitter"] as? NSNumber)?.doubleValue {
                    jitterMs = jitter * 1000.0
                }
                if let fps = (values["framesPerSecond"] as? NSNumber)?.doubleValue {
                    framesPerSecond = fps
                }

            default:
                break
            }
        }

        // Bitrate from bytesReceived delta between this report and the previous one.
        var bitrateKbps: Double?
        let nowUs = report.timestamp_us
        if hasInboundVideo {
            if let prevBytes = previousBytesReceived, let prevUs = previousTimestampUs {
                let deltaSeconds = (nowUs - prevUs) / 1_000_000.0
                let deltaBytes = bytesReceived - prevBytes
                if deltaSeconds > 0, deltaBytes >= 0 {
                    bitrateKbps = (deltaBytes * 8.0) / deltaSeconds / 1000.0
                }
            }
            previousBytesReceived = bytesReceived
            previousTimestampUs = nowUs
        }

        lock.unlock()

        let stats = LiveRelayStats(rttMs: rttMs,
                                   bitrateKbps: bitrateKbps,
                                   packetsLost: packetsLost,
                                   jitterMs: jitterMs,
                                   framesPerSecond: framesPerSecond)
        DispatchQueue.main.async { [weak self] in
            self?.onStats?(stats)
        }
    }
}
