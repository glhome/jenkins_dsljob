def call(Map cfg = [:]) {
    def profile = cfg.profile ?: 'windows10-21h2'
    def targetKb = (cfg.targetKb ?: 'KB5126657').toString().toUpperCase()
    def expectedBuild = cfg.expectedBuild ?: '19044.7807'
    def baseVhdxPath = cfg.baseVhdxPath?.toString()?.trim()
    def vmName = cfg.vmName?.toString()?.trim()
    def hyperVSwitch = cfg.hyperVSwitch?.toString()?.trim()
    def guestCredentialsId = cfg.guestCredentialsId?.toString()?.trim()
    def artifactoryBaseUrl = cfg.artifactoryBaseUrl ?: 'http://localhost:8082/'
    def artifactoryRepo = cfg.artifactoryRepo ?: 'snapshot-generic-local'
    def artifactTransferMethod = cfg.artifactTransferMethod ?: 'JFrog'
    def agentLabel = cfg.agentLabel ?: 'windows-image-builder'
    def keepVm = cfg.containsKey('keepVm') ? cfg.keepVm : true

    if (profile != 'windows10-21h2') error("This experiment currently supports windows10-21h2 only; received '${profile}'.")
    if (!(targetKb ==~ /KB[0-9]+/)) error("TARGET_KB must use the KBnnnnnnn format; received '${targetKb}'.")
    if (!expectedBuild?.trim()) error('EXPECTED_BUILD is required.')
    if (!baseVhdxPath) error('BASE_VHDX_PATH must point to a clean, bootable Windows 10 IoT Enterprise LTSC 2021 VHDX.')
    if (!vmName) error('VM_NAME is required.')
    if (!hyperVSwitch) error('HYPERV_SWITCH is required.')
    if (!guestCredentialsId) error('GUEST_CREDENTIALS_ID is required.')
    if (!artifactoryBaseUrl?.trim()) error('ARTIFACTORY_BASE_URL is required.')

    node(agentLabel) {
        def workRoot = env.WORKSPACE
        def imageInfo = null
        echo "Online servicing experiment: profile=${profile}, target=${targetKb}, expectedBuild=${expectedBuild}, vm=${vmName}; publish=false; ISO capture=false; lastpatch unchanged."

        stage('Hyper-V Preflight') {
            def preflight = libraryResource('scripts/windows-image/online-vm-preflight.ps1')
            def preflightPath = "${workRoot}\\online-vm-preflight.ps1"
            writeFile(file: preflightPath, text: preflight)
            powershell(script: "& '${preflightPath}' -VhdxPath '${baseVhdxPath.replace("'", "''")}' -SwitchName '${hyperVSwitch.replace("'", "''")}' -VmName '${vmName.replace("'", "''")}'")
        }

        stage('Resolve / Download Update') {
            windowsImagePrepare(workRoot: workRoot)
            imageInfo = windowsImageDownload(
                workRoot: workRoot,
                baseIsoArtifact: 'Windows10/21H2/x64/base/en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso',
                baseIsoSha256: 'a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160',
                profile: profile,
                architecture: 'x64',
                artifactoryBaseUrl: artifactoryBaseUrl,
                artifactoryRepo: artifactoryRepo,
                artifactTransferMethod: artifactTransferMethod
            )
            if (imageInfo.cacheHit) error('Patched-image cache hit detected. Refusing to use an offline-patched image for online-servicing validation.')
            if (!targetKb.equalsIgnoreCase(imageInfo.kb?.toString())) error("Resolved KB ${imageInfo.kb} does not match requested ${targetKb}; refusing to service VM.")
            if (!expectedBuild.equals(imageInfo.lcuBuild?.toString())) error("Resolved build ${imageInfo.lcuBuild} does not match expected ${expectedBuild}; refusing to service VM.")
        }

        stage('Online Install and Verify') {
            withCredentials([usernamePassword(credentialsId: guestCredentialsId, usernameVariable: 'WINDOWS_IMAGE_GUEST_USER', passwordVariable: 'WINDOWS_IMAGE_GUEST_PASSWORD')]) {
                def scriptPath = "${workRoot}\\online-vm-update.ps1"
                writeFile(file: scriptPath, text: libraryResource('scripts/windows-image/online-vm-update.ps1'))
                def command = "& '${scriptPath}' -WorkRoot '${workRoot.replace("'", "''")}' -VmName '${vmName.replace("'", "''")}' -VhdxPath '${baseVhdxPath.replace("'", "''")}' -SwitchName '${hyperVSwitch.replace("'", "''")}' -TargetKB '${targetKb}' -ExpectedBuild '${expectedBuild}' -GuestUser \$env:WINDOWS_IMAGE_GUEST_USER -GuestPassword \$env:WINDOWS_IMAGE_GUEST_PASSWORD -KeepVm:\$${keepVm ? 'true' : 'false'}"
                powershell(script: command)
            }
        }

        stage('Result') {
            echo "Online servicing validation passed for ${targetKb}; expected build ${expectedBuild}. No ISO was captured and no patched-image artifact or lastpatch pointer was published."
        }
    }
}
