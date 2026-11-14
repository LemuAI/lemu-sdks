// Shared Maven Central publishing setup, applied by lemu-core and lemu-android after they
// declare their publication. Nothing here runs unless a publish task is called.
//
// Gradle properties (or ORG_GRADLE_PROJECT_<name> environment variables):
//   signingInMemoryKey          ASCII-armored private GPG key
//   signingInMemoryKeyId        optional short key id
//   signingInMemoryKeyPassword  key passphrase
// Without a key, artifacts are published unsigned (fine for mavenLocal, rejected by Central).

apply(plugin = "maven-publish")
apply(plugin = "signing")

fun prop(name: String): String? = (findProperty(name) as String?)?.takeIf { it.isNotBlank() }

val pomArtifactId = prop("POM_ARTIFACT_ID") ?: project.name

configure<PublishingExtension> {
    repositories {
        maven {
            name = "staging"
            url = uri(rootProject.layout.buildDirectory.dir("staging-deploy"))
        }
    }
    publications.withType<MavenPublication>().configureEach {
        groupId = project.group.toString()
        artifactId = pomArtifactId
        version = project.version.toString()
        pom {
            name.set(prop("POM_NAME") ?: pomArtifactId)
            description.set(prop("POM_DESCRIPTION") ?: "Lemu analytics SDK")
            url.set(prop("POM_URL"))
            licenses {
                license {
                    name.set(prop("POM_LICENSE_NAME"))
                    url.set(prop("POM_LICENSE_URL"))
                    distribution.set("repo")
                }
            }
            developers {
                developer {
                    id.set(prop("POM_DEVELOPER_ID"))
                    name.set(prop("POM_DEVELOPER_NAME"))
                    url.set(prop("POM_DEVELOPER_URL"))
                }
            }
            scm {
                url.set(prop("POM_SCM_URL"))
                connection.set(prop("POM_SCM_CONNECTION"))
                developerConnection.set(prop("POM_SCM_DEV_CONNECTION"))
            }
        }
    }
}

val signingKey = prop("signingInMemoryKey")
if (signingKey != null) {
    configure<SigningExtension> {
        useInMemoryPgpKeys(prop("signingInMemoryKeyId"), signingKey, prop("signingInMemoryKeyPassword") ?: "")
        sign(the<PublishingExtension>().publications)
    }
}
