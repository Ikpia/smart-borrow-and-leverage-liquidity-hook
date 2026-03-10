# Security Policy

## Scope

This repo contains experimental DeFi contracts and demo tooling. Do not treat as audited production code.

## Reporting

Please open a private disclosure to maintainers with:

- affected contract/file,
- exploit preconditions,
- impact assessment,
- minimal reproducible steps.

## Threat model highlights

- tick-based in-pool pricing is conservative but still manipulable in extreme low-liquidity contexts,
- liquidation and bad-debt paths are deterministic but can still realize supplier loss under extreme market moves,
- flash paths are optional and capped, but should remain disabled in production unless fully audited.
