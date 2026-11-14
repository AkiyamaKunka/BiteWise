pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Aliyun mirrors first, for the owner's Mac only: Maven Central and
        // Google are TLS-reset-prone from that network (mainland China); the
        // mirrors carry the same artifacts. Never on CI (GitHub Actions sets
        // CI=true), so the signed release builds and the PR builds resolve
        // only from Google, Maven Central and the Gradle Plugin Portal. Any
        // other build can opt out with -Pchopstats.noMirror=true (or that
        // line in ~/.gradle/gradle.properties). The same rule is in
        // build.gradle.kts; docs/RELEASING.md § 9 has the troubleshooting.
        val useMirror =
            System.getenv("CI") != "true" &&
                providers.gradleProperty("chopstats.noMirror").orNull != "true"
        if (useMirror) {
            maven { url = uri("https://maven.aliyun.com/repository/public") }
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
