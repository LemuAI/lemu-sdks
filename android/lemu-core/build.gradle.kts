import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("org.jetbrains.kotlin.jvm")
    `java-library`
}

java {
    sourceCompatibility = JavaVersion.VERSION_1_8
    targetCompatibility = JavaVersion.VERSION_1_8
    withSourcesJar()
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_1_8)
        // Java callers passing null must never get an exception from the SDK.
        freeCompilerArgs.addAll("-Xno-param-assertions", "-Xno-call-assertions", "-Xno-receiver-assertions")
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("com.networknt:json-schema-validator:1.5.1")
}

tasks.test {
    // The shared spec and conformance files live next to this project in the lemu-sdks repo.
    systemProperty("lemu.sdks.root", rootProject.projectDir.parentFile.absolutePath)
    testLogging {
        events("passed", "skipped", "failed")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

// Maven Central needs a javadoc jar; the API reference lives in the KDoc in the sources jar and README.
val javadocJar by tasks.registering(Jar::class) {
    archiveClassifier.set("javadoc")
    from(rootProject.file("README.md"))
}

extra["POM_ARTIFACT_ID"] = "analytics-core"
extra["POM_NAME"] = "Lemu Analytics Core"
extra["POM_DESCRIPTION"] = "Platform-independent core of the Lemu analytics SDK: queue, batching, retries."

apply(from = rootProject.file("gradle/publishing.gradle.kts"))

configure<PublishingExtension> {
    publications {
        create<MavenPublication>("release") {
            from(components["java"])
            artifact(javadocJar)
        }
    }
}
