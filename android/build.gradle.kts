allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Flutter plugins hardcode different Java levels in their own build files
// (tflite_flutter uses 11, camera_android_camerax uses 17) while the Kotlin
// compiler defaults to whatever JDK runs Gradle. That mismatch fails the build
// with "Inconsistent JVM Target Compatibility", and no single global value fixes
// it. Instead, align each module's Kotlin target to that module's own Java target.
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        val javaTaskName = name.removeSuffix("Kotlin") + "JavaWithJavac"
        val matchingJavaTarget = project.provider {
            val javaTask = project.tasks.findByName(javaTaskName) as? JavaCompile
            org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(
                javaTask?.targetCompatibility ?: "17",
            )
        }
        compilerOptions {
            jvmTarget.set(matchingJavaTarget)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
