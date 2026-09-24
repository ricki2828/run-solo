plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.runsolo"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.runsolo"
        // Plan §10: minSdk 29, targetSdk/compileSdk 36 (Play requires API 36 for new apps since 31-Aug-2026).
        minSdk = 29
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    lint {
        // lintVital on the release AAB would fail on MissingPermission in the BLE/location
        // callbacks that are guarded at runtime (the service checks before starting).
        checkReleaseBuilds = false
        // CI runs `:app:lintDebug` with only NewApi: any framework/JDK call above minSdk 29
        // without a version guard fails the build (core-jvm is covered by -Xjdk-release=1.8).
        checkOnly += setOf("NewApi")
        abortOnError = true
    }

    buildFeatures {
        // BuildConfig.DEBUG gates replay mode and the debug intents (plan §12).
        buildConfig = true
    }

    buildTypes {
        debug {
            // Dogfood builds install beside the Play build (plan §11).
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Pure Kotlin core (journal codec, lap state machine, ...) from the included build
    // android/core-jvm; substituted by coordinates via includeBuild in settings.gradle.kts.
    implementation("app.runsolo:core-jvm")
    implementation("androidx.core:core-ktx:1.15.0")
    // FusedLocationProvider (plan §3); falls back to raw GPS_PROVIDER when GMS is missing.
    // play-services-location does not declare INTERNET (dependency audit, plan §10).
    implementation("com.google.android.gms:play-services-location:21.3.0")
}
