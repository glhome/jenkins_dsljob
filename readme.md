# Jenkins DSL & Shared Library

This repository contains the Jenkins infrastructure configuration and reusable Jenkins Pipeline Shared Library used for CI/CD automation.

The repository has two primary responsibilities:

1. **Jenkins Job DSL** — creates and manages Jenkins folders, views, jobs, and seed jobs.
2. **Jenkins Shared Library** — provides reusable Pipeline functions for LabVIEW and similar build pipelines.

---

## Repository Structure

```text
jenkins_dsljob/
│
├── README.md
│
├── vars/
│   ├── labviewPipeline.groovy
│   ├── labviewBuild.groovy
│   ├── labviewPackage.groovy
│   ├── labviewUnitTest.groovy
│   ├── labviewConfig.groovy
│   ├── labviewEnvironment.groovy
│   ├── labviewMetadata.groovy
│   ├── labviewNotifications.groovy
│   └── artifactoryPublish.groovy
│
├── src/
│   └── ...
│
├── resources/
│   └── ...
│
└── jenkins-infra/
    │
    ├── seed/
    │   └── seed.groovy
    │
    ├── folders/
    │   ├── root.groovy
    │   ├── bridge.groovy
    │   ├── catalys.groovy
    │   └── utilities.groovy
    │
    ├── views/
    │   ├── all.groovy
    │   ├── bridge.groovy
    │   └── catalys.groovy
    │
    ├── jobs/
    │   └── bridge/
    │       └── installer.groovy
    │
    └── pipelines/
        └── bridge/
            └── installer.groovy
```

---

# 1. `vars/` — Shared Pipeline Library

The `vars/` directory contains reusable Jenkins Pipeline steps.

These files are automatically exposed by Jenkins when the repository is configured as a Shared Library.

For example:

```groovy
@Library('jnj-jenkins-shared') _

labviewPipeline(
    productName: 'Catalys',
    ...
)
```

### Shared Library modules

| File                          | Purpose                                                                 |
| ----------------------------- | ----------------------------------------------------------------------- |
| `labviewPipeline.groovy`      | Main reusable LabVIEW Pipeline                                          |
| `labviewBuild.groovy`         | Executes LabVIEW Build Specs                                            |
| `labviewPackage.groovy`       | Creates ZIP packages using 7-Zip                                        |
| `labviewUnitTest.groovy`      | Runs LabVIEW unit tests and packages reports                            |
| `labviewConfig.groovy`        | Copies configuration files and folders                                  |
| `labviewEnvironment.groovy`   | Validates and initializes the build environment and clones dependencies |
| `labviewMetadata.groovy`      | Generates build/version/commit metadata                                 |
| `artifactoryPublish.groovy`   | Uploads build artifacts and publishes Build Info                        |
| `labviewNotifications.groovy` | Sends build notifications and email                                     |

The goal is to keep product-specific Jenkinsfiles small and configuration-driven.

---

# 2. `src/` — Shared Library Classes

The `src/` directory is reserved for reusable Groovy classes.

Use this directory when functionality becomes complex enough to justify a class rather than a simple Pipeline step.

Example:

```text
src/
└── com/
    └── jnj/
        └── ci/
            └── LabVIEWBuild.groovy
```

Most normal Pipeline functionality should remain in `vars/`.

---

# 3. `resources/` — Static Shared Library Resources

The `resources/` directory contains static files used by the Shared Library.

Examples:

```text
resources/
├── templates/
├── configuration/
└── scripts/
```

This directory is optional and should only be populated when static resources are required.

---

# 4. `jenkins-infra/` — Jenkins Job DSL

The `jenkins-infra/` directory contains the Jenkins infrastructure configuration.

It is responsible for creating Jenkins objects using Job DSL.

```text
jenkins-infra/
├── seed/
├── folders/
├── views/
├── jobs/
└── pipelines/
```

---

## 4.1 `jenkins-infra/seed/`

Contains the Jenkins seed job definition.

```text
seed/
└── seed.groovy
```

The seed job executes the Job DSL scripts and creates/updates Jenkins jobs, folders, and views.

---

## 4.2 `jenkins-infra/folders/`

Defines Jenkins folder structure.

```text
folders/
├── root.groovy
├── bridge.groovy
├── catalys.groovy
└── utilities.groovy
```

Example hierarchy:

```text
Jenkins
│
├── Bridge
│
├── Catalys
│
└── Utilities
```

Folders are managed independently from Pipeline implementation.

---

## 4.3 `jenkins-infra/views/`

Defines Jenkins views.

```text
views/
├── all.groovy
├── bridge.groovy
└── catalys.groovy
```

Views determine how Jenkins jobs are displayed to users.

Example:

```text
Bridge
├── Installer
├── Build
└── Unit Test

Catalys
├── Build
├── Installer
└── Release
```

Views should remain separate from the job definitions.

---

# 5. `jenkins-infra/jobs/`

Contains Job DSL definitions for Jenkins jobs.

Example:

```text
jobs/
└── bridge/
    └── installer.groovy
```

A Job DSL file defines the Jenkins job itself.

For example:

```groovy
pipelineJob('Bridge/Installer') {
    ...
}
```

The Job DSL determines:

* Job name
* Folder
* SCM configuration
* Jenkinsfile location
* Parameters
* Triggers
* Credentials
* Pipeline configuration

---

# 6. `jenkins-infra/pipelines/`

Contains the Jenkinsfile or Pipeline configuration associated with Job DSL jobs.

Example:

```text
pipelines/
└── bridge/
    └── installer.groovy
```

The Pipeline implementation can consume the Shared Library:

```groovy
@Library('jnj-jenkins-shared') _

labviewPipeline(
    ...
)
```

This keeps the Job DSL configuration separate from the actual Pipeline logic.

---

# Architecture

The overall architecture is:

```text
                    Git Repository
                 jenkins_dsljob
                       │
          ┌────────────┴────────────┐
          │                         │
          ▼                         ▼
   Jenkins Job DSL            Shared Library
   jenkins-infra/                  vars/
          │                         │
          ▼                         ▼
   Jenkins Jobs              Reusable Pipeline
          │                         │
          └────────────┬────────────┘
                       │
                       ▼
                LabVIEW Build
                       │
          ┌────────────┼────────────┐
          ▼            ▼            ▼
       Build         Test       Package
          │            │            │
          └────────────┼────────────┘
                       ▼
                  Artifactory
```

---

# Shared Library Flow

A product-specific Jenkinsfile should contain primarily configuration:

```groovy
@Library('jnj-jenkins-shared') _

labviewPipeline(

    productName: 'Catalys',

    jobBaseName: 'bridge_lv',

    productVersion: 'v1.0',

    nodeLabel: 'CatalysBuild_VM148',

    ...
)
```

The implementation remains inside:

```text
vars/labviewPipeline.groovy
```

which calls the reusable modules:

```text
labviewPipeline
      │
      ├── labviewEnvironment
      │
      ├── labviewBuild
      │
      ├── labviewConfig
      │
      ├── labviewPackage
      │
      ├── labviewUnitTest
      │
      ├── labviewMetadata
      │
      ├── artifactoryPublish
      │
      └── labviewNotifications
```

---

# Jenkins Shared Library Configuration

The repository is configured in Jenkins as a Global Shared Library.

Example:

```text
Library Name:
    jnj-jenkins-shared

Default Version:
    main

SCM:
    Git

Repository:
    https://github.com/glhome/jenkins_dsljob.git
```

The library name is referenced by Jenkinsfiles:

```groovy
@Library('jnj-jenkins-shared') _
```

The name `jnj-jenkins-shared` is a Jenkins configuration name. It does not need to match the Git repository name.

---

# Design Principles

### Separate infrastructure from implementation

```text
jenkins-infra/
    → Jenkins structure

vars/
    → reusable Pipeline implementation
```

### Keep product Jenkinsfiles configuration-driven

Product pipelines should describe:

* Product name
* LabVIEW version
* Build node
* Projects
* Build Specs
* Dependencies
* Packaging
* Unit tests
* Artifactory configuration

They should not duplicate common build logic.

### Reuse common functionality

Similar LabVIEW products can use the same:

```groovy
labviewPipeline(...)
```

with different configuration.

For example:

```text
Catalys
   │
   └── labviewPipeline(config)

Product B
   │
   └── labviewPipeline(config)

Product C
   │
   └── labviewPipeline(config)
```

This allows improvements to the common build process to be made once in the Shared Library rather than separately in every Jenkinsfile.

---

# Build Isolation

Build output should be isolated by Jenkins build number.

Recommended:

```text
C:\builds\
└── bridge_lv\
    ├── 101\
    ├── 102\
    └── 103\
```

This prevents concurrent Jenkins executors from interfering with each other's build output.

Avoid globally deleting:

```text
C:\builds
```

at the beginning of a build.

---

# Branch and Release Strategy

The Shared Library should be versioned independently from product releases.

Development:

```groovy
@Library('jnj-jenkins-shared@main') _
```

Production:

```groovy
@Library('jnj-jenkins-shared@v1.0.0') _
```

Recommended release flow:

```text
main
 │
 ├── development
 │
 ├── testing
 │
 └── v1.0.0
       │
       └── Production pipelines
```

This prevents an untested Shared Library change from unexpectedly changing every production pipeline.

---

# Adding a New LabVIEW Product

To add another product:

1. Create the Jenkins Job DSL definition under:

```text
jenkins-infra/jobs/<product>/
```

2. Add the product folder if required:

```text
jenkins-infra/folders/<product>.groovy
```

3. Add the required view:

```text
jenkins-infra/views/<product>.groovy
```

4. Create a small product Pipeline/Jenkinsfile.

5. Import the Shared Library:

```groovy
@Library('jnj-jenkins-shared') _
```

6. Call:

```groovy
labviewPipeline(...)
```

7. Provide product-specific configuration.

No new copy of the common LabVIEW build logic should be created.

---

# Summary

The repository follows this separation:

```text
jenkins_dsljob/
│
├── vars/
│   └── Reusable Pipeline functionality
│
├── src/
│   └── Shared Library classes
│
├── resources/
│   └── Shared Library resources
│
└── jenkins-infra/
    ├── seed/
    │   └── Seed Job
    │
    ├── folders/
    │   └── Jenkins folders
    │
    ├── views/
    │   └── Jenkins views
    │
    ├── jobs/
    │   └── Job DSL definitions
    │
    └── pipelines/
        └── Product-specific Pipeline configuration
```

**One repository, two purposes:**

```text
                    jenkins_dsljob
                          │
             ┌────────────┴────────────┐
             │                         │
       Jenkins Job DSL          Jenkins Shared Library
             │                         │
     Create Jenkins jobs        Reuse Pipeline logic
             │                         │
             └────────────┬────────────┘
                          │
                          ▼
                    Product Pipelines
```
