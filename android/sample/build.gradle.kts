import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.lemuai.analytics.sample"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.lemuai.analytics.sample"
        minSdk = 21
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
        // Point the sample at a local or QA host with -PlemuApiHost=... and -PlemuWriteKey=...
        buildConfigField("String", "LEMU_WRITE_KEY", "\"${findProperty("lemuWriteKey") ?: "pk_test_sample"}\"")
        buildConfigField("String", "LEMU_API_HOST", "\"${findProperty("lemuApiHost") ?: "https://app.lemuai.com"}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_1_8)
    }
}

dependencies {
    implementation(project(":lemu-android"))
    // -PwithoutInstallReferrer checks that apps without the optional library still build and minify.
    if (!hasProperty("withoutInstallReferrer")) {
        implementation("com.android.installreferrer:installreferrer:2.2")
    }
}
