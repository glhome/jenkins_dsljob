pipelineJob('utilities/windows-image-online') {
    description('Experimental Windows 10 online servicing in an isolated Hyper-V VM. Phase 1 validates KB installation only; it does not capture or publish an ISO.')
    logRotator { numToKeep(10); daysToKeep(14) }
    parameters {
        stringParam('WINDOWS_PROFILE', 'windows10-21h2', 'Currently supported profile.')
        stringParam('TARGET_KB', 'KB5126657', 'Expected cumulative update KB.')
        stringParam('EXPECTED_BUILD', '19044.7807', 'Expected build after installation.')
        stringParam('BASE_VHDX_PATH', '', 'Path on the agent to a clean, bootable Windows 10 IoT Enterprise LTSC 2021 VHDX.')
        stringParam('VM_NAME', 'windows-image-online-test', 'Dedicated Hyper-V VM name.')
        stringParam('HYPERV_SWITCH', '', 'Existing Hyper-V virtual switch. Required.')
        stringParam('GUEST_CREDENTIALS_ID', 'windows-image-guest-admin', 'Jenkins username/password credential for the guest administrator.')
        stringParam('ARTIFACTORY_BASE_URL', 'http://localhost:8082/', 'JFrog Artifactory base URL.')
        stringParam('ARTIFACTORY_REPO', 'snapshot-generic-local', 'Artifactory repository.')
        choiceParam('ARTIFACT_TRANSFER_METHOD', ['JFrog', 'InvokeWebRequest'], 'Artifactory transfer implementation.')
        stringParam('AGENT_LABEL', 'windows-image-builder', 'Agent with Hyper-V and PowerShell Direct.')
        booleanParam('KEEP_VM', true, 'Keep the VM after the run. The VHDX is never deleted.')
    }
    definition {
        cps {
            script('''
@Library('jenkins_dsljob') _

windowsImageOnlinePipeline(
    profile: params.WINDOWS_PROFILE,
    targetKb: params.TARGET_KB,
    expectedBuild: params.EXPECTED_BUILD,
    baseVhdxPath: params.BASE_VHDX_PATH,
    vmName: params.VM_NAME,
    hyperVSwitch: params.HYPERV_SWITCH,
    guestCredentialsId: params.GUEST_CREDENTIALS_ID,
    artifactoryBaseUrl: params.ARTIFACTORY_BASE_URL,
    artifactoryRepo: params.ARTIFACTORY_REPO,
    artifactTransferMethod: params.ARTIFACT_TRANSFER_METHOD,
    agentLabel: params.AGENT_LABEL,
    keepVm: params.KEEP_VM
)
'''.stripIndent())
            sandbox()
        }
    }
}
