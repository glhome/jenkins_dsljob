```groovy
pipelineJob('managed/gui') {

    description('Managed GUI sample pipeline')

    parameters {
        stringParam(
            'BRANCH',
            'main',
            'Git branch to build'
        )

        booleanParam(
            'CLEAN_BUILD',
            false,
            'Perform a clean build'
        )
    }

    definition {
        cps {
            script(readFileFromWorkspace('pipelines/managed/bgui.groovy'))
            sandbox()
        }
    }

    logRotator {
        numToKeep(20)
        daysToKeep(30)
    }
}
```
