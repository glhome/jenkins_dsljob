def email(Map args = [:]) {

    def config =
        args.config ?: [:]

    if (config.enabled == false) {
        return
    }

    def recipients =
        config.recipients ?:
        'jgonz301, clynch22, jli230'

    def artifactRepository =
        config.repository ?:
        'tadh-generic-snapshot'

    def artifactPath =
        config.path ?:
        'Bridge/Builds'

    def artifactUrl =
        "https://artifactrepo.jnj.com/" +
        "artifactory/webapp/#/artifacts/browse/tree/General/" +
        "${artifactRepository}/" +
        "${artifactPath}/" +
        "${args.productVersion}/" +
        "${args.jobBaseName}/" +
        "${args.buildNumber}"

    emailext(

        attachLog:
            args.attachLog ?: false,

        subject:
            "${args.jobName} Build: ${args.result}",

        recipientProviders: [

            [$class: 'CulpritsRecipientProvider'],

            [$class: 'DevelopersRecipientProvider'],

            [$class: 'RequesterRecipientProvider']
        ],

        to:
            recipients,

        body:
"""
Build #${args.buildNumber} ran on ${args.nodeName}
and terminated with ${args.result}.

Build log:
${args.buildUrl}console

Build artifacts:
${artifactUrl}
"""
    )
}