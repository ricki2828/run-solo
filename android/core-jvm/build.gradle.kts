import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework
import org.jetbrains.kotlin.gradle.targets.native.tasks.KotlinNativeSimulatorTest

plugins {
    kotlin("multiplatform") version "2.4.0"
}

group = "app.runsolo"
version = "0.1.0"

// Kotlin Multiplatform (plan K1): the JVM target is what Android has always consumed (same
// bytecode level, same calls: see src/jvmMain); the Apple targets feed the iOS/watchOS recorder
// and are only declared on a macOS host, so the Linux CI and the dev box never download
// Kotlin/Native.
val appleHost = System.getProperty("os.name").startsWith("Mac")

kotlin {
    jvmToolchain(21)
    jvm {
        compilerOptions {
            // Compile against the Java 8 API surface (javac --release 8): anything newer than the
            // JDK APIs Android 10 (API 29, minSdk) ships fails at compile time instead of with
            // NoSuchMethodError on the phone (Stream.toList(), Optional.isEmpty, String.repeat...).
            jvmTarget.set(JvmTarget.JVM_1_8)
            freeCompilerArgs.add("-Xjdk-release=1.8")
        }
    }
    if (appleHost) {
        // K3: the iPhone app links a static XCFramework (RunCore) with the ios-arm64 and
        // ios-arm64-simulator slices (`assembleRunCoreReleaseXCFramework`). macosArm64 only runs
        // the common tests natively on the CI runner and is not part of the framework.
        val xcf = XCFramework("RunCore")
        listOf(iosArm64(), iosSimulatorArm64()).forEach {
            it.binaries.framework {
                baseName = "RunCore"
                isStatic = true
                xcf.add(this)
            }
        }
        macosArm64()
    }

    compilerOptions {
        // expect/actual classes (IOException, the test JavaRandom) are still Beta.
        freeCompilerArgs.add("-Xexpect-actual-classes")
    }

    sourceSets {
        commonTest {
            kotlin.srcDir(layout.buildDirectory.dir("generated/testPaths"))
            dependencies { implementation(kotlin("test")) }
        }
    }
}

// The checked-in java {} block: the JVM target's Java compile matches the Kotlin jvmTarget above
// (Gradle fails on an inconsistent JVM target otherwise).
tasks.withType<JavaCompile>().configureEach {
    sourceCompatibility = JavaVersion.VERSION_1_8.toString()
    targetCompatibility = JavaVersion.VERSION_1_8.toString()
}

// Fixture paths for the common tests: relative to this directory on the JVM (the test working
// directory); a Native test binary needs the absolute path.
val writeTestPaths by tasks.registering {
    val out = layout.buildDirectory.file("generated/testPaths/app/runsolo/core/testio/CoreJvmDir.kt")
    val dir = projectDir.absolutePath
    inputs.property("dir", dir)
    outputs.file(out)
    doLast {
        out.get().asFile.writeText("package app.runsolo.core.testio\n\nconst val CORE_JVM_DIR = \"$dir\"\n")
    }
}
tasks.matching { it.name.startsWith("compileTestKotlin") || it.name == "compileKotlinMetadata" }.configureEach {
    dependsOn(writeTestPaths)
}

tasks.named<Test>("jvmTest") {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
        // The assertion message and cause in the CI log (the host cannot run Gradle to see them).
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

// CI passes the newest simulator on the runner image; the plugin's default device may not exist.
tasks.withType<KotlinNativeSimulatorTest>().configureEach {
    providers.gradleProperty("core.simDevice").orNull?.takeIf { it.isNotEmpty() }?.let { device.set(it) }
}

// Writes every generated fixture (contract run files, event trace) into core-jvm and the
// run_engine copy; see RegenerateFixtures.kt.
tasks.register<JavaExec>("regenerateFixtures") {
    group = "verification"
    val jvmTest = kotlin.jvm().compilations.getByName("test")
    dependsOn(jvmTest.compileTaskProvider)
    classpath = files(jvmTest.output.allOutputs, jvmTest.runtimeDependencyFiles)
    mainClass.set("app.runsolo.core.contract.RegenerateFixturesKt")
    workingDir = projectDir
}
