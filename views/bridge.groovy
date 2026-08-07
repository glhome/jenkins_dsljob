listView('Bridge Builds') {

    description('Bridge CI/CD')

    jobs {
        regex('Bridge/.*')
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