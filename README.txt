Windows Image Factory - Profile Update

Applies to glhome/jenkins_dsljob main branch.

Purpose:
- Keep the existing Windows 11 24H2 / build 26100 pipeline flow.
- Add a profile selector for Windows 10 21H2 / build 19044.
- Remove WINDOWS_BUILD as the profile selector; the profile owns the expected build.
- Use profile-specific Artifactory paths and ISO names.
- Keep the existing CPS-safe PowerShell JSON parsing approach.
- Publish patched/<profile>/lastpatch.txt as the moving patch pointer.
- Do not publish latest.txt.

Files included:
- resources/scripts/windows-image/profiles.ps1       NEW
- resources/scripts/windows-image/resolve-updates.ps1
- resources/scripts/windows-image/download.ps1
- resources/scripts/windows-image/generate-manifest.ps1
- vars/windowsImagePipeline.groovy
- vars/windowsImageDownload.groovy
- vars/windowsImageManifest.groovy
- vars/windowsImagePublish.groovy
- jenkins-infra/jobs/utilities/windows_image.groovy

Important:
1. BASE_ISO_ARTIFACT and BASE_ISO_SHA256 default to __PROFILE_DEFAULT__.
   The pipeline automatically selects the matching profile values. Explicit
   parameter values can still override the profile defaults.
2. Windows 11 24H2 defaults to the existing base ISO and checksum.
3. Windows 10 21H2 / build 19044 is preconfigured with this base ISO:
   Windows10/21H2/x64/base/19044.1288.211006-0501.21h2_release_svc_refresh_CLIENT_BUSINESS_VOL_x64FRE_en-us.iso
   SHA256: 1323fd1ef0cbfd4bf23fa56a6538ff69dd410ad49969983fee3df936a6c811c5
4. The Windows 10 profile currently supports x64.
5. Versioned ISO/SHA/manifest artifacts remain immutable. lastpatch.txt is
   intentionally overwritten on a successful publish.
6. The profile file is copied into the Jenkins workspace and explicitly passed
   to the resolver; this avoids relying on the resolver's PSScriptRoot.

Expected paths:
Windows11/24H2/x64/patched/<LCU_BUILD>/...
Windows11/24H2/x64/patched/lastpatch.txt

Windows10/21H2/x64/patched/<LCU_BUILD>/...
Windows10/21H2/x64/patched/lastpatch.txt

After copying these files into the repository, regenerate the Job DSL seed /
configuration so utilities/windows-image receives the WINDOWS_PROFILE choice.
