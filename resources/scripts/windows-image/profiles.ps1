Set-StrictMode -Version Latest

function Get-WindowsImageProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    switch ($Name.ToLowerInvariant()) {
        'windows11-24h2' {
            [pscustomobject]@{
                Name           = 'windows11-24h2'
                Product        = 'Windows11'
                WindowsVersion = 'Windows 11 24H2'
                CatalogProductPattern = 'Windows 11,\s*version 24H2'
                CatalogBuildRequired  = $true
                CatalogSecurityUpdatesRequired = $true
                Release        = '24H2'
                Build          = '26100'
                BuildRegex     = '26100\.\d+'
                CatalogQuery   = 'Windows 11 24H2 cumulative update x64'
                ArtifactRoot   = 'Windows11/24H2'
                IsoPrefix      = 'Windows11-24H2'
                BaseIsoArtifact = 'Windows11/24H2/x64/base/en-us_windows_11_iot_enterprise_version_24h2_x64_dvd_3a99b72b.iso'
                BaseIsoSha256   = 'eceb8dc167077e07f9a9bd04e472ea542944974b81b2ebc25477772a71bdbb69'
            }
        }
        'windows10-21h2' {
            [pscustomobject]@{
                Name           = 'windows10-21h2'
                Product        = 'Windows10'
                WindowsVersion = 'Windows 10 21H2'
                CatalogProductPattern = '(?i)Windows 10\s*,?\s*version 21H2'
                CatalogBuildRequired  = $false
                CatalogSecurityUpdatesRequired = $false
                Release        = '21H2'
                Build          = '19044'
                BuildRegex     = '19044\.\d+'
                CatalogQuery   = 'Windows 10 Version 21H2 cumulative update x64'
                ArtifactRoot   = 'Windows10/21H2'
                IsoPrefix      = 'Windows10-21H2'
                BaseIsoArtifact = 'Windows10/21H2/x64/base/en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso'
                BaseIsoSha256   = 'a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160'
            }
        }
        default {
            throw "Unknown Windows image profile '$Name'. Supported profiles: windows11-24h2, windows10-21h2"
        }
    }
}
