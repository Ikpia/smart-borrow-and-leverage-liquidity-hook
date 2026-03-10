# Contributing

## Setup

```bash
./scripts/bootstrap.sh
forge test
```

## Standards

- keep changes deterministic and reproducible,
- avoid breaking ABI compatibility without explicit note,
- include tests for every behavioral change,
- keep O(1) debt accounting invariants intact.

## Suggested workflow

1. create a feature branch,
2. add/adjust tests first,
3. implement minimal secure change,
4. run `forge test` and `forge coverage --report summary`,
5. export shared ABIs with `make abis`.
