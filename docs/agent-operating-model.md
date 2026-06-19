# Agent Operating Model

Agents may draft, validate, refine and recommend baseline and installation changes. They must use declared contracts, surface missing decisions and preserve human approval gates.

Agents must not:

- Approve their own sprint work.
- Change baseline behavior without human approval.
- Merge pull requests without human acceptance.
- Close issues without human acceptance.
- Infer product deployment from catalog membership.
- Add product-specific behavior to Hermes Base.

Product needs belong in product repositories; planning and deployment intent belong in `hermes-roadmap`.
