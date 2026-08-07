listView('Catalys Builds') {

    description('Catalys CI/CD')

    jobs {
        regex('Catalys/.*')
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