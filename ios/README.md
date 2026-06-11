# LiveRelaySDK

SDK iOS pour **LiveRelay**, le SFU WebRTC ultra-low-latency (`https://sfu.kudo-ai.com`).

4 modes : **Publisher** (broadcast caméra+micro), **Subscriber** (réception broadcast), **CallSession** (appel 1:1 bidirectionnel), **ConferenceSession** (N-parties).

- iOS 15+
- Swift Concurrency (async/await)
- H.264 hardware (VideoToolbox), Opus tuné low-latency
- Seule dépendance : [stasel/WebRTC](https://github.com/stasel/WebRTC) (binaire WebRTC officiel)

## Installation (Swift Package Manager)

Dans Xcode : **File → Add Package Dependencies…** puis l'URL du repo du SDK.

Ou dans votre `Package.swift` :

```swift
dependencies: [
    .package(url: "https://github.com/your-org/LiveRelaySDK.git", from: "1.0.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "LiveRelaySDK", package: "LiveRelaySDK")
        ]
    )
]
```

Le SDK tire automatiquement `https://github.com/stasel/WebRTC.git` (from: `120.0.0`).

## Configuration

Tous les modes s'initialisent avec une `LiveRelayConfig` :

```swift
import LiveRelaySDK

let config = LiveRelayConfig(
    baseURL: URL(string: "https://sfu.kudo-ai.com")!,
    token: "<JWT>"
)
```

## Delegate

Les 4 sessions notifient via `LiveRelaySessionDelegate` :

```swift
import WebRTC

final class SessionObserver: LiveRelaySessionDelegate {
    func session(_ session: AnyObject, didChangeState state: SessionState) {
        print("state:", state)
    }
    func session(_ session: AnyObject, didReceiveVideoTrack track: RTCVideoTrack, peerId: String?) {
        // Afficher le track avec LiveRelayVideoView (voir Rendu vidéo)
    }
    func session(_ session: AnyObject, didReceiveAudioTrack track: RTCAudioTrack, peerId: String?) {
        // L'audio joue automatiquement
    }
}
```

## Publisher — diffuser caméra + micro

```swift
let publisher = Publisher(config: config, room: "my-room")
publisher.delegate = observer

// Capture locale (défauts : caméra frontale, 1280x720 @ 30 fps)
try await publisher.capture.startCamera(position: .front, width: 1280, height: 720, fps: 30)
publisher.capture.startMicrophone()

try await publisher.start()            // broadcast caméra
// ou : try await publisher.start(screen: true)   // flux écran

// Changer de caméra en cours de diffusion
try await publisher.capture.switchCamera()

// Arrêt
publisher.stop()
```

## Subscriber — recevoir un broadcast

```swift
let subscriber = Subscriber(config: config, room: "my-room")
subscriber.delegate = observer

try await subscriber.start()
// Les tracks distants arrivent via didReceiveVideoTrack / didReceiveAudioTrack

subscriber.stop()
```

## CallSession — appel 1:1 bidirectionnel

```swift
let call = CallSession(config: config, room: "call-abc")
call.delegate = observer

try await call.capture.startCamera(position: .front, width: 1280, height: 720, fps: 30)
call.capture.startMicrophone()

try await call.start()
// Vidéo/audio distants via le delegate, vidéo locale via call.capture.videoTrack

call.stop()
```

## ConferenceSession — N-parties

```swift
let conference = ConferenceSession(config: config, room: "team-standup")
conference.delegate = observer

try await conference.capture.startCamera(position: .front, width: 1280, height: 720, fps: 30)
conference.capture.startMicrophone()

// Join + souscription automatique à chaque participant déjà présent
try await conference.start()
print("mon peerId:", conference.peerId ?? "-")

// Souscrire manuellement à un participant arrivé plus tard
try await conference.subscribeTo(peerId: "peer-123")

conference.stop()
```

## Rendu vidéo (SwiftUI)

`LiveRelayVideoView` enveloppe `RTCMTLVideoView` (rendu Metal) :

```swift
import SwiftUI
import LiveRelaySDK
import WebRTC

struct CallView: View {
    @State var remoteTrack: RTCVideoTrack?
    @State var localTrack: RTCVideoTrack?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LiveRelayVideoView(track: remoteTrack)
                .ignoresSafeArea()
            LiveRelayVideoView(track: localTrack)
                .frame(width: 120, height: 213)
                .cornerRadius(12)
                .padding()
        }
    }
}
```

Assignez `remoteTrack` depuis `didReceiveVideoTrack`, et `localTrack` depuis `session.capture.videoTrack`.

## Info.plist — permissions requises

La capture caméra/micro exige ces clés dans l'`Info.plist` de l'app (sinon crash au premier accès) :

```xml
<key>NSCameraUsageDescription</key>
<string>L'app utilise la caméra pour la vidéo en direct.</string>
<key>NSMicrophoneUsageDescription</key>
<string>L'app utilise le micro pour l'audio en direct.</string>
```

## Audio en arrière-plan

Pour que l'audio continue quand l'app passe en arrière-plan (appel, conférence) :

1. Dans Xcode : **Signing & Capabilities → Background Modes → Audio, AirPlay, and Picture in Picture** (clé `UIBackgroundModes` = `audio` dans l'Info.plist).
2. Le SDK configure l'`AVAudioSession` en `.playAndRecord` / mode `.voiceChat` (haut-parleur par défaut, Bluetooth autorisé) via `AudioSessionConfigurator.configureForVoiceChat()`. Vous pouvez l'appeler vous-même si votre app gère sa propre session audio :

```swift
try AudioSessionConfigurator.configureForVoiceChat()
```

Note : la capture **vidéo** est suspendue par iOS en arrière-plan ; seul l'audio continue.

## Gestion d'erreurs

Toutes les opérations async lancent `LiveRelayError` :

```swift
do {
    try await publisher.start()
} catch let LiveRelayError.http(status, body) {
    print("HTTP \(status): \(body)")
} catch let LiveRelayError.signaling(message) {
    print("signaling: \(message)")
} catch let LiveRelayError.webrtc(message) {
    print("webrtc: \(message)")
} catch LiveRelayError.notConnected {
    print("pas connecté")
}
```
