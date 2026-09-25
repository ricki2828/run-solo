// `java.util.*` cannot be written inline here: `java` resolves to the java {} extension accessor.
import java.util.Base64
import java.util.Properties

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

        // Google Maps key (plan §18.3): env RUN_SOLO_MAPS_API_KEY (CI secret), else the Gradle
        // property / local.properties entry `runsolo.mapsApiKey`, else "" so builds without the
        // secret still pass (the app shows its "Map failed to load" state). Never printed.
        manifestPlaceholders["mapsApiKey"] = mapsApiKey()
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

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    buildFeatures {
        // BuildConfig.REPLAY_ENABLED gates replay mode and the debug intents (plan §12);
        // it is true for every debug build and for the dogfood flavour's release build.
        buildConfig = true
    }

    signingConfigs {
        // Play upload key (plan §11): repo secrets RUN_SOLO_UPLOAD_* decoded to a temp file by
        // ci.yml; Play App Signing holds the app-signing key. Offline copy under
        // ~/.secrets/run-solo/. Absent -> debug key, so PR builds and `flutter run --release`
        // still configure; the release-aab job fails if the key is missing.
        create("upload") {
            val ksPath = System.getenv("RUN_SOLO_UPLOAD_KEYSTORE")
            if (ksPath != null) {
                storeFile = file(ksPath)
                storePassword = System.getenv("RUN_SOLO_UPLOAD_STORE_PASSWORD")
                keyAlias = System.getenv("RUN_SOLO_UPLOAD_KEY_ALIAS") ?: "upload"
                keyPassword = System.getenv("RUN_SOLO_UPLOAD_KEY_PASSWORD")
            } else {
                initWith(getByName("debug"))
            }
        }
        // CI dogfood key: repo secrets decoded to a temp file by ci.yml (RUN_SOLO_DOGFOOD_*).
        // Offline copy under ~/.secrets/run-solo/. Absent locally -> debug key, so the
        // variant still configures; the CI job fails if the key is missing.
        create("dogfood") {
            val ksPath = System.getenv("RUN_SOLO_DOGFOOD_KEYSTORE")
            if (ksPath != null) {
                storeFile = file(ksPath)
                storePassword = System.getenv("RUN_SOLO_DOGFOOD_STORE_PASSWORD")
                keyAlias = System.getenv("RUN_SOLO_DOGFOOD_KEY_ALIAS")
                keyPassword = System.getenv("RUN_SOLO_DOGFOOD_KEY_PASSWORD")
            } else {
                initWith(getByName("debug"))
            }
        }
    }

    flavorDimensions += "dist"
    productFlavors {
        // Play track: applicationId app.runsolo (reserved for Play-signed builds).
        create("play") {
            dimension = "dist"
            buildConfigField("boolean", "REPLAY_ENABLED", "false")
            // Upload key when RUN_SOLO_UPLOAD_KEYSTORE is set (release-aab job), debug key otherwise.
            // The debug build type keeps its own debug signing (build type wins over flavour).
            signingConfig = signingConfigs.getByName("upload")
        }
        // Sideloadable optimised build for the founder's Pixel: release-mode AOT + R8,
        // arm64 only, own key, replay/debug intents kept for desk testing.
        create("dogfood") {
            dimension = "dist"
            applicationIdSuffix = ".dogfood"
            versionNameSuffix = "-dogfood"
            buildConfigField("boolean", "REPLAY_ENABLED", "true")
            signingConfig = signingConfigs.getByName("dogfood")
        }
    }

    buildTypes {
        debug {
            // Debug builds install beside the Play build (plan §11).
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            buildConfigField("boolean", "REPLAY_ENABLED", "true")
        }
        release {
            // Signing is per flavour (see productFlavors); nothing set here so the flavour wins.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

// See defaultConfig: env, then the Flutter --dart-define of the same name (the tool passes
// them as -Pdart-defines=<base64 KEY=VALUE>,...), then -Prunsolo.mapsApiKey / local.properties,
// then empty. Dart reads its copy with String.fromEnvironment('RUN_SOLO_MAPS_API_KEY'); both
// must be the same value, which is why CI passes one env var to both.
fun mapsApiKey(): String {
    System.getenv("RUN_SOLO_MAPS_API_KEY")?.takeIf { it.isNotBlank() }?.let { return it }
    (project.findProperty("dart-defines") as String?)?.split(",")?.forEach { encoded ->
        val decoded = runCatching { String(Base64.getDecoder().decode(encoded)) }.getOrNull() ?: return@forEach
        if (decoded.startsWith("RUN_SOLO_MAPS_API_KEY=")) {
            decoded.removePrefix("RUN_SOLO_MAPS_API_KEY=").takeIf { it.isNotBlank() }?.let { return it }
        }
    }
    (project.findProperty("runsolo.mapsApiKey") as String?)?.takeIf { it.isNotBlank() }?.let { return it }
    val local = rootProject.file("local.properties")
    if (local.exists()) {
        val props = Properties()
        local.inputStream().use { props.load(it) }
        props.getProperty("runsolo.mapsApiKey")?.takeIf { it.isNotBlank() }?.let { return it }
    }
    return ""
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Robolectric unit tests (isIncludeAndroidResources) package the merged assets, which the Flutter
// plugin writes in copyFlutterAssetsDebug without declaring the dependency; Gradle 9 fails the
// build on the implicit ordering. Declare it explicitly.
afterEvaluate {
    val unitTestPackage = Regex("^package(\\w+)DebugUnitTestForUnitTest$")
    tasks.matching { unitTestPackage.matches(it.name) }.configureEach {
        val flavour = unitTestPackage.find(name)!!.groupValues[1]
        dependsOn(tasks.matching { it.name == "copyFlutterAssets${flavour}Debug" })
    }
}

dependencies {
    // Pure Kotlin core (journal codec, lap state machine, ...) from the included build
    // android/core-jvm; substituted by coordinates via includeBuild in settings.gradle.kts.
    implementation("app.runsolo:core-jvm")
    implementation("androidx.core:core-ktx:1.15.0")
    // FusedLocationProvider (plan §3); falls back to raw GPS_PROVIDER when GMS is missing.
    // play-services-location does not declare INTERNET (dependency audit, plan §10).
    implementation("com.google.android.gms:play-services-location:21.3.0")
    // JVM unit tests (StartGuard, and the real RecordingSession under Robolectric); CI runs :app:testDebugUnitTest.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}
