listView('Catalys Builds') {

    description('Catalys CI/CD jobs')

    jobs {
        recurse()
        regex('^Catalys/.*')
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