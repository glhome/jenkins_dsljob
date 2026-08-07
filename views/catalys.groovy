listView('Catalys Builds') {

    description('Catalys CI/CD')

    jobs {
        name('Catalys/Installer')
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