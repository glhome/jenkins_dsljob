listView('Managed Bridge Builds') {

    description('Managed Bridge CI/CD jobs')

    jobs {
        recurse()
        regex('^managed/bridge/.*')
    }

    columns {
        status()
        weather()
        name()
        lastSuccess()
        lastFailure()
        lastDuration()
        buildButton()
    }
}