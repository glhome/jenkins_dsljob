pipelineJob('utilities/windows-image') {
    description('Builds a serviced Windows ISO from an immutable Artifactory base ISO using a Windows image profile.')
    logRotator { numToKeep(20); daysToKeep(30) }
    parameters {
        choiceParam('WINDOWS_PROFILE', ['windows11-24h2', 'windows10-21h2'], 'Windows image profile')
        stringParam('BASE_ISO_ARTIFACT','__PROFILE_DEFAULT__','Base Windows ISO path in Artifactory. Use __PROFILE_DEFAULT__ to select the ISO defined by WINDOWS_PROFILE.')
        stringParam('BASE_ISO_SHA256','__PROFILE_DEFAULT__','Base ISO SHA-256. Use __PROFILE_DEFAULT__ to select the checksum defined by WINDOWS_PROFILE.')
        stringParam('ARCHITECTURE','x64','Windows architecture')
        stringParam('ARTIFACTORY_BASE_URL','http://localhost:8082/','JFrog Artifactory base URL')
        stringParam('ARTIFACTORY_REPO','snapshot-generic-local','Artifactory repository containing Windows base ISOs and updates')
        stringParam('IMAGE_INDEX','1','install.wim image index')
        stringParam('AGENT_LABEL','windows-image-builder','Jenkins agent label')
        booleanParam('KEEP_WORKSPACE',false,'Keep image workspace after the build')
        choiceParam('ARTIFACT_TRANSFER_METHOD',['InvokeWebRequest', 'JFrog'],'Artifactory transfer implementation')
    }
    definition {
        cps {
            script('''
@Library('jenkins_dsljob') _

windowsImagePipeline(
    profile: params.WINDOWS_PROFILE,
    baseIsoArtifact: params.BASE_ISO_ARTIFACT,
    baseIsoSha256: params.BASE_ISO_SHA256,
    architecture: params.ARCHITECTURE,
    artifactoryBaseUrl: params.ARTIFACTORY_BASE_URL,
    artifactoryRepo: params.ARTIFACTORY_REPO,
    imageIndex: params.IMAGE_INDEX,
    agentLabel: params.AGENT_LABEL,
    keepWorkspace: params.KEEP_WORKSPACE,
    artifactTransferMethod: params.ARTIFACT_TRANSFER_METHOD
)
'''.stripIndent())
            sandbox()
        }
    }
}
