# Agent Instructions

## Repository Scope

This repository contains the shared Hermes foundation, not product-specific behavior. Maintain reusable contracts, schemas, bootstrap rules, baseline configuration, automation contracts and shared infrastructure.

Do not implement TaskMe, Investments, Multichannel, WhatsApp Group Personality or other product-specific logic here. Redirect product-specific needs to the relevant product repository or planning decisions to `hermes-roadmap`.

## Standards

- Keep all repository content in professional English.
- Prefer readable, machine-valid contracts over premature runtime code.
- Keep schemas simple and aligned with their configuration examples.
- Preserve compatibility or clearly document breaking changes.
- Add open questions instead of inventing critical decisions.

## Human Approval

Human approval is required before changing baseline behavior, deployment rules, sprint commitment, pull request merge or issue closure.

Agents may draft, validate and recommend changes. They must not approve their own work, activate product deployment, merge pull requests or close work items without human acceptance.

## Repository Boundaries

- Product and installation intent belongs in `hermes-roadmap`.
- Reusable executable foundation contracts belong here.
- Product-specific implementation belongs in product repositories.

A product catalog entry does not mean that the product is deployed. Deployment must be explicitly approved for the target installation.
