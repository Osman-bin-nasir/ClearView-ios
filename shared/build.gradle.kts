import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    // Newest stable Kotlin. Deliberately NOT pinned to the app's 2.2.10: this
    // build must work with Xcode 26.5 / the iOS 26.5 SDK, and Kotlin 2.4.21 is
    // the release that targets that toolchain. The two builds are independent —
    // bumping this module's Kotlin cannot affect the Android app.
    kotlin("multiplatform") version "2.4.21"
    // `kotlinx.serialization` replaces `org.json`, which the Android app uses
    // but which does not exist on Kotlin/Native. The compiler plugin generates
    // the serializers from @Serializable declarations.
    kotlin("plugin.serialization") version "2.4.21"
}

kotlin {
    // The JVM target is the fast feedback loop: `commonTest` runs here in a
    // second, with no simulator. It is not shipped to anyone; it exists so a
    // change to shared logic fails loudly and immediately. JVM 11 bytecode to
    // match the Android app's `sourceCompatibility`/`targetCompatibility`.
    jvm {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_11)
        }
    }

    // iOS targets. This is an Intel Mac, so the simulator that runs locally is
    // x86_64 → `iosX64` is the target we can actually launch. `iosArm64` is a
    // physical device; `iosSimulatorArm64` is a future Apple-silicon Mac or a
    // CI runner. All three are declared so the framework builds anywhere.
    listOf(iosX64(), iosArm64(), iosSimulatorArm64()).forEach { iosTarget ->
        iosTarget.binaries.framework {
            // The name Swift imports: `import SharedKotlin`.
            baseName = "SharedKotlin"
            // Static: one less dynamic dylib to embed and sign, and the module
            // has no runtime dependencies of its own yet.
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            // JSON: the multiplatform replacement for `org.json`, which is an
            // Android/JVM artifact and does not exist on Kotlin/Native.
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
