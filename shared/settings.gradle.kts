// The ClearView shared module is its OWN Gradle build, deliberately.
//
// The Android application lives in a single module (`:app`) at the repository
// root and applies the Android Gradle Plugin. Configuring that module requires a
// local Android SDK. Keeping this module in a separate build means
// `./gradlew -p shared …` never configures `:app`, so the shared Kotlin (and the
// iOS framework it produces) can be built and tested on a machine with Xcode but
// no Android SDK — and, just as importantly, nothing about the existing Android
// build changes while we work.
//
// Wiring `:app` to consume this module later is a one-line `includeBuild("shared")`
// in the root settings, and is deferred until the Android SDK question is settled.
pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
        google()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

rootProject.name = "clearview-shared"
