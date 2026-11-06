import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The override lets CI or a maintainer keep the password file outside the checkout.
val signingPropertiesPath = System.getenv("HOPBOARD_ANDROID_KEY_PROPERTIES")
val signingPropertiesFile = if (signingPropertiesPath.isNullOrBlank()) {
    rootProject.file("key.properties")
} else {
    require(File(signingPropertiesPath).isAbsolute) {
        "HOPBOARD_ANDROID_KEY_PROPERTIES must be an absolute path."
    }
    File(signingPropertiesPath)
}
val signingProperties = Properties()
if (signingPropertiesFile.isFile) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
    val required = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    require(required.all { !signingProperties.getProperty(it).isNullOrBlank() }) {
        "Android signing properties require storeFile, storePassword, keyAlias and keyPassword."
    }
}
val releaseKeystore = signingProperties.getProperty("storeFile")?.let {
    val path = File(it)
    if (path.isAbsolute) path else File(signingPropertiesFile.parentFile, it)
}
if (releaseKeystore != null) {
    require(releaseKeystore.isFile) { "Android release keystore was not found. See docs/tutorial/release-signing.md." }
}

val missingSigningMessage = "Android release signing is not configured. Create android/key.properties or set " +
    "HOPBOARD_ANDROID_KEY_PROPERTIES. See docs/tutorial/release-signing.md. " +
    "Release builds never use the debug key."
// Fail explicit release requests before Gradle resolves SDK/build dependencies.
if (releaseKeystore == null && gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }) {
    throw GradleException(missingSigningMessage)
}
// Also cover aggregate tasks such as 'assemble'; debug builds and IDE sync need no release key.
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any {
        it.project == project && it.name.contains("Release", ignoreCase = true)
    }
    if (buildsRelease && releaseKeystore == null) {
        throw GradleException(missingSigningMessage)
    }
}

android {
    namespace = "dev.localclipboard.local_clipboard"
    compileSdk = 37
    // SDK 37 is published as android-37.0; keep the minor level explicit.
    compileSdkMinor = 0
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Permanent distribution identity; changing this creates a separate app.
        // The Kotlin namespace above can remain independent of the application ID.
        applicationId = "io.github.azrinfreeman.hopboard"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29
        targetSdk = 37
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
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
