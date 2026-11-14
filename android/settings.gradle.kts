pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "lemu-android-sdk"

include(":lemu-core")

// The Android modules need an Android SDK. Without one (for example a plain JVM CI job),
// only the pure Kotlin core is built and tested.
fun androidSdkAvailable(): Boolean {
    val env = System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT")
    if (env != null && file(env).isDirectory) return true
    val local = file("local.properties")
    if (local.isFile) {
        val props = java.util.Properties()
        local.inputStream().use { props.load(it) }
        val dir = props.getProperty("sdk.dir")
        if (dir != null && file(dir).isDirectory) return true
    }
    return false
}

if (androidSdkAvailable()) {
    include(":lemu-android")
    include(":sample")
} else {
    logger.warn("Android SDK not found (set ANDROID_HOME or sdk.dir in local.properties): building lemu-core only")
}
