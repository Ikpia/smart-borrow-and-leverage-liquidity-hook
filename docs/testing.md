# Testing

## Coverage classes in this repo

- Unit tests:
  - market accounting,
  - risk model,
  - router,
  - liquidations.
- Fuzz tests:
  - borrow-bound safety,
  - debt monotonicity,
  - healthy liquidation predicate,
  - flash path repayment.
- Invariant tests:
  - debt/risk snapshot consistency,
  - healthy <-> liquidatable predicate consistency.
- Integration tests:
  - lifecycle with real v4 pool + swaps + hook updates.

## Run

```bash
forge test
forge test --match-path test/fuzz/ProtocolFuzz.t.sol
forge test --match-path test/fuzz/ProtocolInvariants.t.sol
./scripts/ensure_coverage_100.sh
```

`scripts/ensure_coverage_100.sh` enforces `100%` line coverage for protocol contracts (excluding `script/`, `test/`, `lib/`, and `src/mocks/`).
