listView('Managed Utilities') {

    description('Managed Jenkins utility jobs')

    jobs {
        recurse()
        regex('^managed/utilities/.*')
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