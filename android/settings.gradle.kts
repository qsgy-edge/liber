pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // Not the 9.0.1 the Flutter 3.44 template writes: AGP 9 evaluates every
    // plugin's own build.gradle too, and this dependency set is not AGP-9 ready.
    // `flutter_inappwebview_android` 1.1.3 (the latest stable, and the version
    // #55's Windows WebView rows rest on) calls
    // `getDefaultProguardFile('proguard-android.txt')`, which AGP 9 removed, and
    // `packages/fjs/android/build.gradle` still declares `compileSdkVersion`,
    // which AGP 9 also removed. Flutter 3.44 supports AGP 8.13 with Gradle 8.13+
    // (`flutter_tools/lib/src/android/gradle_utils.dart`, the AGP/Gradle table);
    // its DependencyVersionChecker errors only below AGP 8.6.0 and warns below
    // 8.11.1, so 8.13.1 is both supported and warning-free. (#68)
    id("com.android.application") version "8.13.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
