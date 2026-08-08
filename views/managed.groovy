listView('Managed Builds') {

    description('Managed CI/CD jobs')

    jobs {
        recurse()
        regex('^Managed/.*')
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