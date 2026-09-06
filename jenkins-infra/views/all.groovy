listView('Managed All') {

    description('All managed Jenkins jobs')

    jobs {
        recurse()
        regex('^managed/.*')
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