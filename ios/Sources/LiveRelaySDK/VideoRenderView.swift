#if canImport(UIKit)
import SwiftUI
import UIKit
import WebRTC

/// SwiftUI wrapper around `RTCMTLVideoView` (Metal renderer) for displaying a `RTCVideoTrack`.
///
/// Handles track changes: the previous track is detached from the renderer
/// before the new one is attached, and the track is detached on dismantle.
@available(iOS 15, *)
public struct LiveRelayVideoView: UIViewRepresentable {
    private let track: RTCVideoTrack?

    public init(track: RTCVideoTrack?) {
        self.track = track
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    public func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        let coordinator = context.coordinator
        // No-op if the same track instance is already attached.
        guard coordinator.attachedTrack !== track else { return }
        // Detach the previously attached track from this renderer.
        coordinator.attachedTrack?.remove(uiView)
        // Attach the new track (if any).
        track?.add(uiView)
        coordinator.attachedTrack = track
    }

    public static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attachedTrack?.remove(uiView)
        coordinator.attachedTrack = nil
    }

    /// Keeps a reference to the track currently attached to the renderer,
    /// so it can be removed when the track changes or the view is dismantled.
    public final class Coordinator {
        var attachedTrack: RTCVideoTrack?
    }
}
#endif
