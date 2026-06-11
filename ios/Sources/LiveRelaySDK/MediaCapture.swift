import Foundation
import AVFoundation
import WebRTC

/// Capture caméra + micro pour LiveRelay.
///
/// - `startCamera` choisit le device par position et le format supporté le plus
///   proche de width×height@fps (résolutions standard uniquement, indispensable
///   pour l'encodeur hardware H.264 / VideoToolbox).
/// - `switchCamera` bascule front/back en conservant le même `RTCVideoTrack`
///   (seul le capturer est re-démarré sur le nouveau device).
public final class MediaCapture {

    public private(set) var videoTrack: RTCVideoTrack?
    public private(set) var audioTrack: RTCAudioTrack?

    private let factory: RTCPeerConnectionFactory
    private var videoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?
    private var currentPosition: AVCaptureDevice.Position = .front
    private var currentWidth: Int = 1280
    private var currentHeight: Int = 720
    private var currentFps: Int = 30

    public init(factory: RTCPeerConnectionFactory) {
        self.factory = factory
    }

    // MARK: - Camera

    public func startCamera(position: AVCaptureDevice.Position = .front,
                            width: Int = 1280,
                            height: Int = 720,
                            fps: Int = 30) async throws {
        currentPosition = position
        currentWidth = width
        currentHeight = height
        currentFps = fps

        let source: RTCVideoSource
        if let existing = videoSource {
            source = existing
        } else {
            source = factory.videoSource()
            videoSource = source
        }

        let capturer: RTCCameraVideoCapturer
        if let existing = self.capturer {
            await existing.stopCapture()
            capturer = existing
        } else {
            capturer = RTCCameraVideoCapturer(delegate: source)
            self.capturer = capturer
        }

        guard let device = Self.device(for: position) else {
            throw LiveRelayError.webrtc("No capture device for position \(position.rawValue)")
        }
        guard let format = Self.bestFormat(for: device, width: width, height: height) else {
            throw LiveRelayError.webrtc("No supported capture format for device \(device.localizedName)")
        }
        let actualFps = Self.bestFps(for: format, target: fps)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            capturer.startCapture(with: device, format: format, fps: actualFps) { error in
                if let error {
                    continuation.resume(throwing: LiveRelayError.webrtc("startCapture failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            }
        }

        if videoTrack == nil {
            let track = factory.videoTrack(with: source, trackId: "liverelay-video0")
            track.isEnabled = true
            videoTrack = track
        }
    }

    public func switchCamera() async throws {
        let newPosition: AVCaptureDevice.Position = (currentPosition == .front) ? .back : .front
        // Même source + même track : seul le device change, re-startCapture.
        try await startCamera(position: newPosition,
                              width: currentWidth,
                              height: currentHeight,
                              fps: currentFps)
    }

    // MARK: - Microphone

    public func startMicrophone() {
        guard audioTrack == nil else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "echoCancellation": "true",
                "noiseSuppression": "true"
            ],
            optionalConstraints: nil
        )
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: "liverelay-audio0")
        track.isEnabled = true
        audioTrack = track
    }

    // MARK: - Stop

    public func stop() {
        capturer?.stopCapture()
        capturer = nil
        videoSource = nil
        videoTrack = nil
        audioTrack = nil
    }

    // MARK: - Device / format selection

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let devices = RTCCameraVideoCapturer.captureDevices()
        return devices.first(where: { $0.position == position }) ?? devices.first
    }

    /// Résolutions standard supportées par l'encodeur hardware H.264.
    private static let standardResolutions: [(width: Int32, height: Int32)] = [
        (3840, 2160),
        (1920, 1080),
        (1280, 720),
        (960, 540),
        (640, 480),
        (640, 360),
        (480, 360),
        (352, 288),
        (320, 240)
    ]

    /// Choisit, parmi les formats supportés du device, celui dont les dimensions
    /// sont standard et les plus proches de la cible width×height.
    private static func bestFormat(for device: AVCaptureDevice, width: Int, height: Int) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard !formats.isEmpty else { return nil }

        let targetPixels = Int64(width) * Int64(height)

        func isStandard(_ dims: CMVideoDimensions) -> Bool {
            standardResolutions.contains { $0.width == dims.width && $0.height == dims.height }
        }
        func distance(_ dims: CMVideoDimensions) -> Int64 {
            abs(Int64(dims.width) * Int64(dims.height) - targetPixels)
                + abs(Int64(dims.width) - Int64(width))
        }

        let standardFormats = formats.filter {
            isStandard(CMVideoFormatDescriptionGetDimensions($0.formatDescription))
        }
        let candidates = standardFormats.isEmpty ? formats : standardFormats

        return candidates.min { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return distance(l) < distance(r)
        }
    }

    /// FPS le plus proche de la cible parmi les plages supportées du format.
    private static func bestFps(for format: AVCaptureDevice.Format, target: Int) -> Int {
        var best = target
        var bestDelta = Int.max
        for range in format.videoSupportedFrameRateRanges {
            let clamped = min(max(Double(target), range.minFrameRate), range.maxFrameRate)
            let delta = abs(Int(clamped.rounded()) - target)
            if delta < bestDelta {
                bestDelta = delta
                best = Int(clamped.rounded())
            }
        }
        return max(best, 1)
    }
}
