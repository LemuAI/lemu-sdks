plugins {
    id("com.android.library") version "8.5.2" apply false
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.jvm") version "2.0.21" apply false
}

allprojects {
    group = property("GROUP") as String
    version = (findProperty("VERSION_NAME") as String?) ?: "0.0.0-SNAPSHOT"
}

// Release bundle for the Maven Central Portal: `./gradlew publishAllPublicationsToStagingRepository`
// writes signed artifacts to build/staging-deploy; CI zips that folder and uploads it.
tasks.register<Delete>("cleanStaging") {
    delete(layout.buildDirectory.dir("staging-deploy"))
}
