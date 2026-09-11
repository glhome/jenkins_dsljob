def call(Map c=[:]) {
 def s=libraryResource('scripts/windows-image/resolve-updates.ps1')
 def p="${env.WORKSPACE}\\resolve-windows-updates.ps1";writeFile file:p,text:s
 def a=["-WorkRoot '${c.workRoot}'","-WindowsBuild '${c.windowsBuild}'","-Architecture '${c.architecture ?: 'x64'}'"]
 if(c.updateManifestUrl)a<<"-UpdateManifestUrl '${c.updateManifestUrl}'"
 else if(c.updateManifestFile)a<<"-UpdateManifestFile '${c.updateManifestFile}'"
 powershell("& '${p}' ${a.join(' ')}")
}
