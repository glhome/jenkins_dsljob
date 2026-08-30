def call(Map args = [:]) {

    def config =
        args.config ?: [:]

    def serverId =
        config.serverId ?: 'artifactory'

    def repository =
        config.repository ?: 'tadh-generic-snapshot'

    def basePath =
        config.path ?: 'Bridge/Builds'

    def target =
        "${repository}/" +
        "${basePath}/" +
        "${args.productVersion}/" +
        "${args.jobBaseName}"

    echo "Artifactory target:"
    echo "${target}"

    rtUpload(

        serverId: serverId,

        spec: """{
            "files": [

                {
                    "pattern":
                        "${args.workspace}/zipfolder/*.zip",

                    "target":
                        "${target}/${env.BUILD_NUMBER}/"
                },

                {
                    "pattern":
                        "${args.workspace}/build.txt",

                    "target":
                        "${target}/${env.BUILD_NUMBER}/"
                },

                {
                    "pattern":
                        "${args.workspace}/lastRelease.txt",

                    "target":
                        "${target}/"
                }

            ]
        }"""
    )

    rtPublishBuildInfo(
        serverId: serverId
    )
}