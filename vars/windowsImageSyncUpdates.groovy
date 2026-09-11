def call(Map c=[:]) {
 def s=libraryResource('scripts/windows-image/sync-updates.ps1')
 def p="${env.WORKSPACE}\\sync-windows-updates.ps1";writeFile file:p,text:s
 powershell("& '${p}' -WorkRoot '${c.workRoot}' -WindowsBuild '${c.windowsBuild}' -Architecture '${c.architecture ?: 'x64'}' -ArtifactoryRepo '${c.artifactoryRepo ?: 'windows-updates'}' -ArtifactoryBaseUrl '${c.artifactoryBaseUrl}'")
}
