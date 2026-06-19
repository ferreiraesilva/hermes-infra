# Hermes Base

Hermes Base is the executable shared foundation for Hermes Agent installations. It provides reusable configuration contracts, schemas, bootstrap guidance, GitHub automation contracts and common agent operating rules.

## What It Is

Hermes Base defines how installations are created, configured, validated and operated. Every Hermes installation should inherit Hermes Base unless the human explicitly approves an exception.

## What It Is Not

Hermes Base is not a product roadmap and does not contain product-specific behavior. It does not decide which products should exist or where they should be deployed.

## Repository Relationships

- `hermes-roadmap` defines what should exist and why, including product governance, installation intent and deployment decisions.
- `hermes-base` implements reusable foundation contracts shared by installations.
- Product repositories implement product-specific behavior.

The product catalog remains in `hermes-roadmap`. A catalog entry does not enable a product in any installation.

## Three-Layer Model

1. **Hermes Base:** inherited global contracts and operating rules.
2. **Hermes Installation:** a concrete agent instance with identity, context, permissions and enabled products.
3. **Product / Module Deployment:** an explicit mapping that enables a product globally, in selected installations or nowhere.

Product deployment is explicit per installation and requires human approval.

## Initial Scope

This repository starts with configuration contracts, JSON schemas, bootstrap documentation, templates and operating rules. Runtime code should be added only for approved reusable foundation needs.
Executable shared foundation for Hermes Agent installations
