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
                Release        = '21H2'
                Build          = '19044'
                BuildRegex     = '19044\.\d+'
                CatalogQuery   = 'Windows 10 Version 21H2 cumulative update x64'
                ArtifactRoot   = 'Windows10/21H2'
                IsoPrefix      = 'Windows10-21H2'
                BaseIsoArtifact = 'Windows10/21H2/x64/base/19044.1288.211006-0501.21h2_release_svc_refresh_CLIENT_BUSINESS_VOL_x64FRE_en-us.iso'
                BaseIsoSha256   = '1323fd1ef0cbfd4bf23fa56a6538ff69dd410ad49969983fee3df936a6c811c5'
            }
        }
        default {
            throw "Unknown Windows image profile '$Name'. Supported profiles: windows11-24h2, windows10-21h2"
        }
    }
}
