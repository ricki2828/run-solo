plugins {
    kotlin("jvm") version "2.4.0"
}

group = "app.runsolo"
version = "0.1.0"

kotlin {
    jvmToolchain(17)
    compilerOptions {
        // Compile against the Java 8 API surface (javac --release 8): anything newer than the
        // JDK APIs Android 10 (API 29, minSdk) ships fails at compile time instead of with
        // NoSuchMethodError on the phone (Stream.toList(), Optional.isEmpty, String.repeat...).
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
        freeCompilerArgs.add("-Xjdk-release=1.8")
    }
}

dependencies {
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
    }
}
