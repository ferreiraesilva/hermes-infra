# Architecture

Hermes Base is the reusable executable foundation between roadmap intent and concrete Hermes installations.

## Layers

1. **Hermes Base** supplies inherited contracts, defaults and operating rules.
2. **Hermes Installation** supplies identity, environment, permissions and enabled products.
3. **Product / Module Deployment** explicitly maps cataloged products to installations.

`hermes-roadmap` owns planning and deployment decisions. Hermes Base owns reusable implementation contracts. Product repositories own product behavior.

Every installation should inherit Hermes Base unless the human explicitly approves an exception.
