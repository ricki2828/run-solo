// K0 spike only (ai/plans/run-supreme-ios-plan.md §2.2): core-jvm as Kotlin Multiplatform.
// Sources come from android/core-jvm via port.py; nothing here is consumed by the app build.
rootProject.name = "kmp-core-spike"

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
