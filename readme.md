jenkins-infra/
├── README.md
├── .gitignore
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
│   ├── catalys.groovy
│   └── utilities.groovy
│
├── jobs/
│   ├── bridge/
│   │   ├── installer.groovy
│   │   ├── gui.groovy
│   │   └── lv.groovy
│   └── utilities/
│       └── repo-scanner.groovy
│
├── pipelines/
│   ├── bridge/
│   │   ├── installer.groovy
│   │   ├── gui.groovy
│   │   └── lv.groovy
│   └── utilities/
│       └── repo-scanner.groovy
│
└── scripts/
    └── scanner/
        ├── scan-repos.ps1
        ├── detect-language.ps1
        ├── detect-build-system.ps1
        └── config.json