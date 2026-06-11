import Foundation
import AVFoundation
import WebRTC

/// Configuration AVAudioSession basse latence pour la voix.
///
/// `.playAndRecord` + mode `.voiceChat` active le chemin audio I/O temps réel
/// d'iOS (~10 ms de latence matérielle) avec AEC hardware. Passe par
/// `RTCAudioSession` (lock/unlock) pour rester cohérent avec la gestion
/// interne de WebRTC.
public enum AudioSessionConfigurator {

    public static func configureForVoiceChat() throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }

        try session.setCategory(
            AVAudioSession.Category.playAndRecord,
            mode: AVAudioSession.Mode.voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true)
    }
}
