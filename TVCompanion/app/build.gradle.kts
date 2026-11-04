plugins {
    id("com.android.application")
}

android {
    namespace = "com.soum91.obsidian.tv"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.soum91.obsidian.tv"
        minSdk = 26
        targetSdk = 35
        val buildNumber = providers.gradleProperty("OBSIDIAN_BUILD_NUMBER")
            .orNull?.toIntOrNull()?.takeIf { it > 0 } ?: 1
        versionCode = buildNumber
        versionName = "0.1.0.$buildNumber"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("com.google.zxing:core:3.5.3")
    implementation("org.eclipse.paho:org.eclipse.paho.client.mqttv3:1.2.5")
}
