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
        // The classic Xposed API is not on Maven Central, only here.
        maven { setUrl("https://api.xposed.info/") }
    }
}

rootProject.name = "cc-qs-tiles"
include(":app")
