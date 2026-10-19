import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.shadow)
}

group = "dev.tachi"
version = "0.1.0"

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        freeCompilerArgs.add("-Xcontext-parameters")
    }
}

// ---------------------------------------------------------------------------
// Android stub jar.
//
// Extensions are compiled against android.jar.  We take a real android.jar
// and strip everything we implement ourselves (so our classes win) plus the
// java.*/javax.*/org.* namespaces (which the JDK provides for real).
// What remains are "throw new RuntimeException("Stub!")" classes that let
// extension bytecode *link* even when it references Android APIs it never
// calls at runtime (Activity, Intent, WebView, ...).
// ---------------------------------------------------------------------------
val androidJarSource: File? = run {
    val explicit = (findProperty("tachi.androidJar") as String?)?.let(::File)
    if (explicit != null && explicit.exists()) return@run explicit
    val sdk = System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT")
        ?: "${System.getProperty("user.home")}/Library/Android/sdk"
    File(sdk, "platforms").listFiles()
        ?.filter { it.name.startsWith("android-") }
        ?.sortedByDescending { it.name.removePrefix("android-").toIntOrNull() ?: 0 }
        ?.map { File(it, "android.jar") }
        ?.firstOrNull { it.exists() }
}

val androidStubs = tasks.register<Zip>("androidStubs") {
    description = "Builds the stripped android.jar stub library the host runs extensions against."
    val src = androidJarSource ?: error(
        "No android.jar found. Install an Android SDK platform, set ANDROID_HOME, " +
            "or pass -Ptachi.androidJar=/path/to/android.jar",
    )
    inputs.file(src)
    from(zipTree(src))
    archiveFileName.set("android-stubs.jar")
    destinationDirectory.set(layout.buildDirectory.dir("android"))
    // Provided by the JDK or by us; never let the stub versions shadow them.
    exclude("java/**", "javax/**", "org/**", "junit/**", "META-INF/**")
    // Classes with real implementations in src/main/java|kotlin (android/..., androidx/...).
    val ours = fileTree("src/main/java") { include("android/**", "androidx/**", "dalvik/**") } +
        fileTree("src/main/kotlin") { include("android/**", "androidx/**", "dalvik/**") }
    ours.visit {
        if (!isDirectory) {
            val base = relativePath.pathString.substringBeforeLast('.')
            exclude("$base.class", "$base$*.class", "${base}Kt.class", "${base}Kt$*.class")
        }
    }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
}

// Only the rewritten jar enters runtimeClasspath. ASM is a build tool only.
val aircompressorOriginal by configurations.creating
val alignmentTools by configurations.creating
val compileAlignmentTool = tasks.register<JavaCompile>("compileAlignmentTool") {
    source("tools/AlignAircompressor.java")
    classpath = alignmentTools
    destinationDirectory.set(layout.buildDirectory.dir("alignment-tool"))
    options.release.set(17)
}
val alignedJar = layout.buildDirectory.file("compat/aircompressor-0.27.jar")
val alignAircompressor = tasks.register<JavaExec>("alignAircompressor") {
    dependsOn(compileAlignmentTool)
    classpath = files(compileAlignmentTool.flatMap { it.destinationDirectory }) + alignmentTools
    mainClass.set("AlignAircompressor")
    inputs.files(aircompressorOriginal)
    outputs.file(alignedJar)
    doFirst { args = listOf(aircompressorOriginal.singleFile.absolutePath, alignedJar.get().asFile.absolutePath) }
}

dependencies {
    compileOnly(files(androidStubs.map { it.archiveFile }))
    // The stubs are also needed at runtime so extension bytecode can link.
    runtimeOnly(files(androidStubs.map { it.archiveFile }))

    implementation(libs.kotlin.stdlib)
    implementation(libs.kotlin.reflect)
    implementation(libs.coroutines.core)
    implementation(libs.serialization.json)
    implementation(libs.serialization.json.okio)
    implementation(libs.serialization.protobuf)
    implementation(libs.okhttp.core)
    implementation(libs.okhttp.brotli)
    // Java-8-compatible, pure Java zstd. No okhttp-zstd / zstd-kmp JNI dependency.
    compileOnly(libs.aircompressor)
    add(aircompressorOriginal.name, libs.aircompressor)
    add(alignmentTools.name, "org.ow2.asm:asm:9.8")
    runtimeOnly(files(alignedJar).builtBy(alignAircompressor))
    implementation(libs.okhttp.logging)
    implementation(libs.jsoup)
    implementation(libs.injekt.core)
    implementation(libs.apk.parser)
    implementation(libs.dex2jar.translator)
    implementation(libs.dex2jar.tools)
}

tasks.shadowJar {
    archiveBaseName.set("tachi-host")
    archiveClassifier.set("")
    archiveVersion.set("")
    mergeServiceFiles()
    // Our android/androidx implementations must win over the stub jar.
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA", "META-INF/versions/9/module-info.class")
}

tasks.build { dependsOn(tasks.shadowJar) }


val testZstd = tasks.register<JavaExec>("testZstd") {
    description = "Check the JNI-free okhttp-zstd ABI, decoding and stream lifecycle."
    dependsOn(tasks.testClasses)
    classpath = sourceSets["test"].runtimeClasspath
    mainClass.set("dev.tachi.host.ZstdCompatibilityTest")
}
tasks.check { dependsOn(testZstd) }


tasks.processResources {
    from("licenses") { into("META-INF/licenses") }
}
