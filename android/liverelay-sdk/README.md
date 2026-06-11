# liverelay-sdk (Android)

SDK Kotlin client du SFU WebRTC **LiveRelay** (`https://sfu.kudo-ai.com`).
Package : `app.orizn.liverelay` — minSdk 24, targetSdk 34, Java 17.

## Installation

Module Gradle local. Copier le dossier `liverelay-sdk/` à la racine du projet, puis :

**settings.gradle.kts**
```kotlin
include(":liverelay-sdk")
```

**app/build.gradle.kts**
```kotlin
dependencies {
    implementation(project(":liverelay-sdk"))
}
```

Dépendances embarquées : `io.getstream:stream-webrtc-android:1.1.1` (exposée en `api`, fournit `org.webrtc`), `okhttp:4.12.0`, `kotlinx-coroutines-android:1.8.0`.

## Initialisation obligatoire

Appeler **une fois au démarrage** (ex. `Application.onCreate`), avant toute session :

```kotlin
import app.orizn.liverelay.PeerConnectionProvider

class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        PeerConnectionProvider.initialize(this)
    }
}
```

## Permissions runtime

Le manifest du SDK déclare `CAMERA`, `RECORD_AUDIO`, `INTERNET`, `MODIFY_AUDIO_SETTINGS`, `ACCESS_NETWORK_STATE`. Les deux premières sont **dangerous** : à demander au runtime avant `start()` :

```kotlin
ActivityCompat.requestPermissions(
    this,
    arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO),
    REQ_MEDIA
)
```

## Configuration

```kotlin
val config = LiveRelayConfig(
    baseUrl = "https://sfu.kudo-ai.com",
    token = "<JWT>" // envoyé en Authorization: Bearer
)
```

Les méthodes `start()` sont des `suspend fun` — à appeler depuis une coroutine (ex. `lifecycleScope.launch { ... }`).

## Les 4 modes

### 1. Publisher (diffuser caméra + micro)

```kotlin
val publisher = Publisher(context, config, room = "ma-room")
publisher.listener = object : LiveRelayListener {
    override fun onStateChanged(state: SessionState) { /* NEW/CONNECTING/CONNECTED/... */ }
    override fun onRemoteVideoTrack(track: VideoTrack, peerId: String?) {}
    override fun onRemoteAudioTrack(track: AudioTrack, peerId: String?) {}
}
lifecycleScope.launch {
    publisher.start()                 // ou publisher.start(screen = true)
}
// Caméra locale : publisher.capture.videoTrack, switchCamera(), etc.
publisher.stop()
```

### 2. Subscriber (regarder un flux)

```kotlin
val subscriber = Subscriber(context, config, room = "ma-room")
subscriber.listener = object : LiveRelayListener {
    override fun onStateChanged(state: SessionState) {}
    override fun onRemoteVideoTrack(track: VideoTrack, peerId: String?) {
        runOnUiThread { videoView.bind(track) }
    }
    override fun onRemoteAudioTrack(track: AudioTrack, peerId: String?) {}
}
lifecycleScope.launch { subscriber.start() }
subscriber.stop()
```

### 3. CallSession (appel 1-à-1, envoi + réception)

```kotlin
val call = CallSession(context, config, room = "call-42")
call.listener = object : LiveRelayListener {
    override fun onStateChanged(state: SessionState) {}
    override fun onRemoteVideoTrack(track: VideoTrack, peerId: String?) {
        runOnUiThread { remoteView.bind(track) }
    }
    override fun onRemoteAudioTrack(track: AudioTrack, peerId: String?) {}
}
lifecycleScope.launch { call.start() }
// Preview locale : localView.bind(call.capture.videoTrack)
call.stop()
```

### 4. ConferenceSession (multi-participants)

```kotlin
val conf = ConferenceSession(context, config, room = "conf-101")
conf.listener = object : LiveRelayListener {
    override fun onStateChanged(state: SessionState) {}
    override fun onRemoteVideoTrack(track: VideoTrack, peerId: String?) {
        // un rendu par peerId
    }
    override fun onRemoteAudioTrack(track: AudioTrack, peerId: String?) {}
}
lifecycleScope.launch {
    conf.start()                       // join + subscribe aux participants existants
    // conf.peerId — notre id attribué par le SFU
}
// Nouveau participant signalé ailleurs ? :
lifecycleScope.launch { conf.subscribeTo(peerId = "abc123") }
conf.stop()
```

## Rendu vidéo — LiveRelayVideoView

`LiveRelayVideoView` étend `SurfaceViewRenderer` (init EGL idempotent + hardware scaler).

```xml
<app.orizn.liverelay.LiveRelayVideoView
    android:id="@+id/remoteView"
    android:layout_width="match_parent"
    android:layout_height="match_parent" />
```

```kotlin
remoteView.bind(track)   // attache une VideoTrack (locale ou distante)
remoteView.unbind()      // détache (à appeler avant release / onDestroy)
```

## Threads

Les callbacks `LiveRelayListener` arrivent sur des threads internes WebRTC — poster vers le main thread (`runOnUiThread`, `Handler`, `Dispatchers.Main`) avant de toucher l'UI.

## Erreurs

Les échecs réseau/signalisation lèvent `LiveRelayException(message, statusCode)`.
