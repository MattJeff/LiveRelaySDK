plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.orizn.liverelay"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        // Note: pas de targetSdk ici — supprimé pour les libraries depuis AGP 9
        // (l'app consommatrice définit le sien).
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Même version que l'app Orizn pour éviter tout conflit de classes org.webrtc.
    api("io.getstream:stream-webrtc-android:1.3.8")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")
}
