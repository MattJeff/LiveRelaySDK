# LiveRelaySDK

SDK natifs iOS et Android pour le SFU WebRTC **LiveRelay** — streaming basse latence (publish, subscribe, appels 1:1, conférences N-parties).

| Plateforme | Dossier | Repo dédié (installation) |
|---|---|---|
| iOS (Swift, SPM, iOS 15+) | [`ios/`](ios/) | [MattJeff/webtrectiossdk](https://github.com/MattJeff/webtrectiossdk) |
| Android (Kotlin, minSdk 24) | [`android/`](android/) | [MattJeff/webrtc-androidsdk](https://github.com/MattJeff/webrtc-androidsdk) |

Ce repo regroupe les deux SDK ; les repos dédiés servent à l'installation (SPM exige `Package.swift` à la racine).

## Fonctionnalités basse latence

- H.264 hardware prioritaire (VideoToolbox / MediaCodec), Opus `minptime=10;useinbandfec=1`
- Attente ICE plafonnée à 2s (candidats partiels), `gatherContinually`, pool de candidats
- `degradationPreference = MAINTAIN_FRAMERATE`, audio session `voiceChat` (iOS) / `MODE_IN_COMMUNICATION` (Android)
- 4 modes : `Publisher`, `Subscriber`, `CallSession`, `ConferenceSession` + `StatsMonitor` (RTT, bitrate, jitter, fps)

Voir le README de chaque SDK pour l'installation et les exemples. Les signatures publiques sont documentées dans `CONTRACTS.md` de chaque dossier.
