listView('Catalys Builds') {

    description('Catalys CI/CD')

    jobs {
        name('catalys/installer')
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