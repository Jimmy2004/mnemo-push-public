plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.mnemo.push"
    compileSdk = 36
    defaultConfig {
        applicationId = "dev.mnemo.push"
        minSdk = 26
        targetSdk = 36
        versionCode = 7
        versionName = "0.3.3"
    }
    // 发布签名：密钥库与密码放在仓库外（~/.gradle/gradle.properties），未配置时 release 不签名
    val ks = providers.gradleProperty("MNEMO_KEYSTORE").orNull
    signingConfigs {
        if (ks != null) create("release") {
            storeFile = file(ks)
            storePassword = providers.gradleProperty("MNEMO_KEYSTORE_PASSWORD").get()
            keyAlias = providers.gradleProperty("MNEMO_KEY_ALIAS").get()
            keyPassword = providers.gradleProperty("MNEMO_KEY_PASSWORD").get()
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            if (ks != null) signingConfig = signingConfigs.getByName("release")
        }
    }
    // full：完整界面；nolog：隐藏底部「最近日志」卡片。两者包名相同，可互相覆盖安装
    flavorDimensions += "ui"
    productFlavors {
        create("full") { dimension = "ui"; resValue("bool", "show_logs", "true") }
        create("nolog") { dimension = "ui"; resValue("bool", "show_logs", "false") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isIncludeAndroidResources = true }
}

dependencies {
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("androidx.work:work-testing:2.10.0")
}
