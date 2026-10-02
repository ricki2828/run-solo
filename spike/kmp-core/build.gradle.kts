import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework
import org.jetbrains.kotlin.gradle.targets.native.tasks.KotlinNativeSimulatorTest

plugins {
    kotlin("multiplatform") version "2.4.0"
}

group = "app.runsolo"
version = "0.0.0-k0"

// Run `python3 port.py` first: it writes build/ported from android/core-jvm.
val ported = layout.projectDirectory.dir("build/ported")
val withWatch = providers.gradleProperty("k0.watch").map { it.toBoolean() }.getOrElse(false)

kotlin {
    jvmToolchain(17)
    jvm {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
            freeCompilerArgs.add("-Xjdk-release=1.8")
        }
    }

    val xcf = XCFramework("RunCore")
    val apple = buildList {
        add(iosArm64())
        add(iosSimulatorArm64())
        add(macosArm64()) // test proxy + `swift test` on the runner
        if (withWatch) {
            add(watchosArm64()) // arm64_32
            add(watchosDeviceArm64())
            add(watchosSimulatorArm64())
        }
    }
    apple.forEach {
        it.binaries.framework {
            baseName = "RunCore"
            isStatic = true
            xcf.add(this)
        }
    }

    compilerOptions {
        freeCompilerArgs.add("-Xexpect-actual-classes")
    }

    sourceSets {
        commonMain { kotlin.srcDir(ported.dir("commonMain/kotlin")) }
        jvmMain { kotlin.srcDir(ported.dir("jvmMain/kotlin")) }
        commonTest {
            kotlin.srcDir(ported.dir("commonTest/kotlin"))
            dependencies { implementation(kotlin("test")) }
        }
    }
}

tasks.named<Test>("jvmTest") {
    useJUnitPlatform()
    testLogging {
        events("failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

tasks.withType<KotlinNativeSimulatorTest>().configureEach {
    providers.gradleProperty("k0.simDevice").orNull?.let { device.set(it) }
}
