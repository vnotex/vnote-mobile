import groovy.json.JsonOutput
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.artifacts.dsl.LockMode
import java.security.MessageDigest
import java.security.KeyStore
import java.security.cert.X509Certificate
import javax.xml.parsers.DocumentBuilderFactory

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val packageMode = providers.environmentVariable("VNOTE_PACKAGE_MODE").orNull
val ownerRelease = packageMode == "owner-release" && gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true) || it.substringAfterLast(':') in setOf("assemble", "bundle", "build")
}
fun protectedValue(name: String): String = providers.environmentVariable(name).orNull
    ?.takeIf { it.isNotBlank() } ?: throw GradleException("Missing protected release input: $name")
fun ownerApplicationId(): String {
    val value = protectedValue("VNOTE_ANDROID_APPLICATION_ID")
    require(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*){2,}").matches(value)
        && !Regex("(^|\\.)(example|test|localhost|invalid)(\\.|$)", RegexOption.IGNORE_CASE).containsMatchIn(value)) {
        "Owner release requires a registered non-development Android application ID"
    }
    return value
}

// Checking the executed graph catches direct Gradle invocations as well as Flutter.
// Debug/profile retain the existing application ID and development signing.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name.contains("Release") }) {
        require(packageMode == "unsigned-validation" || ownerRelease) {
            "Release packaging is gated: use scripts/release.mjs android unsigned-validation or owner-release"
        }
        if (ownerRelease) ownerApplicationId()
    }
}

android {
    namespace = "com.example.vnote_mobile"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Development identity only; store identity requires owner configuration.
        applicationId = "com.example.vnote_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = 36
        ndk { abiFilters += setOf("arm64-v8a", "x86_64") }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (ownerRelease) {
            create("ownerRelease") {
                storeFile = file(protectedValue("VNOTE_ANDROID_KEYSTORE"))
                require(storeFile!!.isFile) { "Protected Android keystore is unavailable" }
                storePassword = protectedValue("VNOTE_ANDROID_STORE_PASSWORD")
                keyAlias = protectedValue("VNOTE_ANDROID_KEY_ALIAS")
                keyPassword = protectedValue("VNOTE_ANDROID_KEY_PASSWORD")
                require(!storeFile!!.name.equals("debug.keystore", ignoreCase = true)
                    && !keyAlias.equals("androiddebugkey", ignoreCase = true)) { "Development signing keys are forbidden for owner release" }
                val fingerprint = protectedValue("VNOTE_ANDROID_CERT_SHA256").replace(":", "").lowercase()
                require(Regex("[a-f0-9]{64}").matches(fingerprint)) { "A protected owner certificate SHA-256 pin is required" }
                val password = storePassword!!.toCharArray()
                try {
                    val store = KeyStore.getInstance(storeFile!!, password)
                    val certificate = store.getCertificate(keyAlias) as? X509Certificate
                        ?: throw GradleException("Owner signing certificate is unavailable")
                    certificate.checkValidity()
                    val actual = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
                        .joinToString("") { "%02x".format(it) }
                    require(actual == fingerprint && !certificate.subjectX500Principal.name.contains("Android Debug", ignoreCase = true))
                } catch (_: Exception) {
                    throw GradleException("Protected owner signing certificate is invalid or does not match its pin")
                } finally { password.fill('\u0000') }
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }
    buildTypes {
        getByName("release") {
            signingConfig = if (ownerRelease) signingConfigs.getByName("ownerRelease") else null
        }
    }
    packaging { jniLibs { useLegacyPackaging = false } }

}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        if (ownerRelease) variant.applicationId.set(ownerApplicationId())
        variant.packaging.jniLibs.excludes.addAll("lib/armeabi-v7a/**", "lib/x86/**")
    }
}

val lockedReleaseConfigurations = setOf("releaseCompileClasspath", "releaseRuntimeClasspath")
dependencyLocking { lockMode.set(LockMode.STRICT) }
configurations.configureEach {
    if (name in lockedReleaseConfigurations) {
        resolutionStrategy.activateDependencyLocking()
        // Strict locks and verification metadata pin versions and artifact bytes.
    }
}

// Resolve actual release artifacts, not a guessed list inferred from group names.
// Paths stay in this ignored build-local handoff; distributable inventories omit them.
tasks.register("dependencyNoticeInputs") {
    doLast {
        require(packageMode == "unsigned-validation" || ownerRelease) { "Select VNOTE_PACKAGE_MODE explicitly" }
        val runtime = configurations.getByName("releaseRuntimeClasspath")
        val artifacts = runtime.incoming.artifactView {
            componentFilter { it is ModuleComponentIdentifier }
        }.artifacts.artifacts
        val modules = runtime.incoming.resolutionResult.allComponents.mapNotNull {
            it.id as? ModuleComponentIdentifier
        }.sortedBy { "${it.group}:${it.module}:${it.version}" }
        val factory = DocumentBuilderFactory.newInstance().apply {
            setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
            setFeature("http://xml.org/sax/features/external-general-entities", false)
            setFeature("http://xml.org/sax/features/external-parameter-entities", false)
        }
        val poms = sortedMapOf<String, String>()
        fun resolvePom(coordinate: String) {
            if (poms.containsKey(coordinate)) return
            val dependency = dependencies.create("$coordinate@pom")
            val configuration = configurations.detachedConfiguration(dependency).apply { isTransitive = false }
            val pom = configuration.singleFile
            poms[coordinate] = pom.absolutePath
            val parents = factory.newDocumentBuilder().parse(pom).documentElement.getElementsByTagName("parent")
            if (parents.length > 0) {
                val parent = parents.item(0) as org.w3c.dom.Element
                fun field(name: String) = parent.getElementsByTagName(name).item(0)?.textContent?.trim()
                    ?: throw GradleException("Incomplete Maven parent metadata")
                val inherited = "${field("groupId")}:${field("artifactId")}:${field("version")}"
                require(!inherited.contains('$')) { "Unresolved Maven parent coordinates" }
                resolvePom(inherited)
            }
        }
        val components = modules.map { id ->
            val coordinate = "${id.group}:${id.module}:${id.version}"
            resolvePom(coordinate)
            val files = artifacts.filter { it.id.componentIdentifier == id }.map { artifact ->
                val digest = MessageDigest.getInstance("SHA-256")
                artifact.file.inputStream().use { input ->
                    val buffer = ByteArray(65536)
                    while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
                }
                mapOf("name" to artifact.file.name, "path" to artifact.file.absolutePath,
                    "sha256" to digest.digest().joinToString("") { "%02x".format(it) })
            }.sortedBy { it["name"] }
            mapOf("coordinate" to coordinate, "artifacts" to files)
        }
        val output = rootProject.file("../../../.tools/notices/android-runtime.json")
        output.parentFile.mkdirs()
        output.writeText(JsonOutput.prettyPrint(JsonOutput.toJson(mapOf(
            "schema" to 1, "configuration" to "releaseRuntimeClasspath", "components" to components, "poms" to poms
        ))) + "\n")
    }
}

tasks.register("resolveDependencyLocks") {
    doLast {
        configurations.filter { it.isCanBeResolved && it.name in lockedReleaseConfigurations }
            .sortedBy { it.name }.forEach { it.incoming.resolutionResult.allComponents }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.webkit:webkit:1.15.0")
}

flutter {
    source = "../.."
}
