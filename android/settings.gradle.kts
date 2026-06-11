pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id("com.android.library") version "8.13.0"
        id("org.jetbrains.kotlin.android") version "2.1.20"
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "liverelay"
include(":liverelay-sdk")
