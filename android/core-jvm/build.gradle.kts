plugins {
    kotlin("jvm") version "2.4.0"
}

group = "app.runsolo"
version = "0.1.0"

java {
    // Must match the Kotlin jvmTarget below or Gradle fails the build ("Inconsistent JVM
    // Target Compatibility"). Bytecode is Java 8; the toolchain that compiles it is JDK 17.
    sourceCompatibility = JavaVersion.VERSION_1_8
    targetCompatibility = JavaVersion.VERSION_1_8
}

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
        // The assertion message and cause in the CI log (the host cannot run Gradle to see them).
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

// Writes every generated fixture (contract run files, event trace) into core-jvm and the
// run_engine copy; see RegenerateFixtures.kt.
tasks.register<JavaExec>("regenerateFixtures") {
    group = "verification"
    classpath = sourceSets["test"].runtimeClasspath
    mainClass.set("app.runsolo.core.contract.RegenerateFixturesKt")
    workingDir = projectDir
}
