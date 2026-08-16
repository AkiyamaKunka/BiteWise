allprojects {
    repositories {
        // Aliyun mirrors first — see settings.gradle.kts (mainland-China TLS).
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Pin every plugin module's Kotlin to the SAME JVM target the app uses
// (JavaVersion.VERSION_17 in app/build.gradle.kts).
//
// Plugins that don't set jvmTarget themselves inherit the toolchain JDK —
// here that is JDK 25, the only modern JDK installed — while their Java
// tasks still compile at 17, and Gradle refuses the mismatch:
//   Inconsistent JVM-target compatibility ... 'compileReleaseJavaWithJavac'
//   (17) and 'compileReleaseKotlin' (25)
// It stayed hidden while the plugins' outputs were cached from an older
// build and surfaced the moment a variant change forced a recompile
// (photo_manager, 2026-08-17).
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>()
        .configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
