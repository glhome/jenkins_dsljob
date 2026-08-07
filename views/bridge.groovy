listView('Bridge Builds') {

    description('Bridge CI/CD jobs')

    jobs {
        recurse()
        regex('^Bridge/.*')
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