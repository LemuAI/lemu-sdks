import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.lemuai.analytics"
    compileSdk = 34

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
            withJavadocJar()
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_1_8)
        freeCompilerArgs.addAll("-Xno-param-assertions", "-Xno-call-assertions", "-Xno-receiver-assertions")
    }
}

dependencies {
    api(project(":lemu-core"))
    // Deliberately old: the lowest version that works, so apps resolve to their own newer one.
    //noinspection GradleDependency
    implementation("androidx.lifecycle:lifecycle-process:2.6.2")
    // Optional: used only when the app itself depends on it.
    compileOnly("com.android.installreferrer:installreferrer:2.2")

    testImplementation("junit:junit:4.13.2")
}

extra["POM_ARTIFACT_ID"] = "analytics"
extra["POM_NAME"] = "Lemu Analytics for Android"
extra["POM_DESCRIPTION"] = "Lemu analytics SDK for Android: events, purchases, lifecycle, deep links and install attribution."

apply(from = rootProject.file("gradle/publishing.gradle.kts"))

afterEvaluate {
    configure<PublishingExtension> {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
            }
        }
    }
}
