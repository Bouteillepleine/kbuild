import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
}

android {
    namespace = "com.xxxy.cctiles"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.xxxy.cctiles"
        minSdk = 34
        targetSdk = 37
        versionCode = 18
        versionName = "2.6"
    }

    // Build with your own key by dropping a keystore.properties in the root:
    //   storeFile=/path/to/key.jks
    //   storePassword=...
    //   keyAlias=...
    //   keyPassword=...
    // Without it the debug key is used, which is fine for a sideloaded module.
    var releaseSigning = signingConfigs.getByName("debug")
    val keystorePropertiesFile = rootProject.file("keystore.properties")
    if (keystorePropertiesFile.exists()) {
        val props = Properties()
        FileInputStream(keystorePropertiesFile).use { props.load(it) }
        releaseSigning = signingConfigs.create("release") {
            storeFile = rootProject.file(props.getProperty("storeFile"))
            storePassword = props.getProperty("storePassword")
            keyAlias = props.getProperty("keyAlias")
            keyPassword = props.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            // Without this the Kotlin stdlib AGP adds ships too, and a one file
            // Java module comes out at 2MB instead of ~20KB.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"),
                    "proguard-rules.pro")
            signingConfig = releaseSigning
        }
        debug {
            signingConfig = releaseSigning
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    lint {
        disable += "MissingApplicationIcon"
    }
}

dependencies {
    // Provided by LSPosed at runtime, never packaged.
    compileOnly("de.robv.android.xposed:api:82")
}
