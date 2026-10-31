def call(Map cfg = [:]) {
    def workRoot = cfg.workRoot
    def profile = cfg.profile
    def imageIndex = cfg.imageIndex as Integer
    if (!workRoot?.trim()) error 'workRoot is required'
    if (!profile?.trim()) error 'profile is required'
    if (imageIndex < 1) error 'imageIndex must be detected before prerequisite resolution'

    def resolver = libraryResource('scripts/windows-image/resolve-updates.ps1')
    def stageScript = libraryResource('scripts/windows-image/resolve-prerequisites.ps1')
    def resolverPath = "${env.WORKSPACE}\\resolve-updates.ps1"
    def stagePath = "${env.WORKSPACE}\\resolve-prerequisites.ps1"
    writeFile(file: resolverPath, text: resolver)
    writeFile(file: stagePath, text: stageScript)

    withCredentials([usernamePassword(credentialsId: 'artifactory-credentials', usernameVariable: 'ARTIFACTORY_USER', passwordVariable: 'ARTIFACTORY_PASSWORD')]) {
        powershell(
            '''
$ErrorActionPreference = 'Stop'
& '__STAGE_PATH__' -WorkRoot '__WORK_ROOT__' -Profile '__PROFILE__' -ImageIndex __IMAGE_INDEX__ `
  -ResolverScriptPath '__RESOLVER_PATH__' -Architecture '__ARCHITECTURE__' `
  -ArtifactoryBaseUrl '__ARTIFACTORY_URL__' -ArtifactoryRepo '__ARTIFACTORY_REPO__' `
  -ArtifactoryUser $env:ARTIFACTORY_USER -ArtifactoryPassword $env:ARTIFACTORY_PASSWORD
if (-not $?) { throw 'Resolve Prerequisites stage failed.' }
'''
                .replace('__STAGE_PATH__', stagePath)
                .replace('__WORK_ROOT__', workRoot)
                .replace('__PROFILE__', profile)
                .replace('__IMAGE_INDEX__', imageIndex.toString())
                .replace('__RESOLVER_PATH__', resolverPath)
                .replace('__ARCHITECTURE__', cfg.architecture ?: 'x64')
                .replace('__ARTIFACTORY_URL__', cfg.artifactoryBaseUrl ?: '')
                .replace('__ARTIFACTORY_REPO__', cfg.artifactoryRepo ?: 'snapshot-generic-local')
        )
    }
}
