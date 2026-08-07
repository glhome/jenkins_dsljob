listView('Bridge Builds') {

    description('Bridge CI/CD')

     jobs {
        name('Bridge/Installer')
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