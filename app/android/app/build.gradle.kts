import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (docs/RELEASING.md § Google Play).
//
// android/key.properties (git-ignored; written by .github/workflows/release.yml
// on CI, by hand on the owner's Mac) carries the upload-key settings:
//
//     storeFile=upload-keystore.jks      # relative to android/, or absolute
//     storePassword=...
//     keyPassword=...
//     keyAlias=upload
//
// Without it the release build is signed with the DEBUG key, as it always
// was, so friends and contributors can still `flutter build apk --release`
// without any keystore. Such a build installs fine but Play rejects it, and
// Android refuses to upgrade between the two signatures.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasUploadKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasUploadKeystore) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
if (!hasUploadKeystore) {
    // logger.quiet, not warn: `flutter build` runs Gradle with -q, which
    // hides WARN-level output; QUIET is the one level that still reaches
    // the terminal.
    logger.quiet(
        "BiteWise: android/key.properties not found - the release build is signed with the " +
            "DEBUG key (installable, NOT uploadable to Google Play). See docs/RELEASING.md.",
    )
}

android {
    namespace = "dev.calorietracker.calorie_tracker"
    // receive_sharing_intent's AAR metadata requires compileSdk >= 37.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time — needs desugaring.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.calorietracker.calorie_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKeystore) {
            create("release") {
                fun required(name: String): String =
                    keystoreProperties.getProperty(name)?.trim()?.takeIf { it.isNotEmpty() }
                        ?: throw GradleException(
                            "android/key.properties exists but has no '$name' (see docs/RELEASING.md § Google Play)",
                        )
                val store = rootProject.file(required("storeFile"))
                if (!store.exists()) {
                    throw GradleException(
                        "android/key.properties: storeFile '${store.path}' does not exist " +
                            "(the path is relative to android/)",
                    )
                }
                storeFile = store
                storePassword = required("storePassword")
                keyAlias = required("keyAlias")
                keyPassword = required("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Upload key when android/key.properties is present, otherwise the
            // debug key so `flutter run --release` keeps working for everyone.
            signingConfig =
                if (hasUploadKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
            // R8 needs explicit keeps for WorkManager's reflective Room setup
            // (release-only startup crash without them — see proguard-rules.pro).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
