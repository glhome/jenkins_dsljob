listView('Managed Catalys Builds') {

    description('Managed Catalys CI/CD jobs')

    jobs {
        recurse()
        regex('^managed/catalys/.*')
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