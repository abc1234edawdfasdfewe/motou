plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.motou.sender"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.motou.sender"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    // 扫码连接：CameraX 预览 + ZXing 解码
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")
    implementation("androidx.activity:activity:1.9.3")
    implementation("com.google.zxing:core:3.5.3")
    // 漫画压缩包：CBR/RAR 解析（CBZ/ZIP 用 JDK 自带 java.util.zip）
    implementation("com.github.junrar:junrar:7.5.5")
    // OCR 拍照：EXIF 方向校正
    implementation("androidx.exifinterface:exifinterface:1.3.7")
}
