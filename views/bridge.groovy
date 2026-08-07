listView('Bridge Builds') {

    description('Bridge CI/CD')

     jobs {
        name('bridge/installer')
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