// Standalone Gradle build: pure Kotlin/JVM, no Android plugin, so it runs on any JDK 17 host
// (including the aarch64 dev box that cannot run aapt2). The app build includes it via
// includeBuild("core-jvm") in android/settings.gradle.kts.
rootProject.name = "core-jvm"

pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}
