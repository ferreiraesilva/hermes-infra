# GitHub Automation Contracts

GitHub automation should create and maintain the fields and views declared in `/config/github-project-defaults.yaml`.

Automation may classify work, populate metadata, prepare sprint candidates and report missing information. It must not approve sprint commitment, merge pull requests, change deployments or close issues without human approval.

Required records should identify product, installation scope, target installations, deployment scope, repository and approval state. Automation must remain idempotent and expose validation failures clearly.
