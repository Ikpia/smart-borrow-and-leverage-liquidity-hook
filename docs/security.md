# Security Notes

## Implemented controls

- Hook entry points restricted by `onlyPoolManager` (`BaseHook`).
- Router/vault/market/liquidation critical paths use access controls.
- Reentrancy guards on user-facing state transitions.
- Borrow bounds enforced by `RiskManager` before leverage actions.
- Slippage/health bounds in router and flash leverage path.
- Flash leverage enforces provider-authenticated callback and atomic flash repayment.

## Key attack surfaces and mitigations

- Price manipulation around borrow:
  - conservative collateral factor + dynamic penalties.
- Sandwiching leverage tx:
  - atomic router flow and post-action health checks.
- Rounding exploitation:
  - scaled debt with explicit full-repay path.
- Liquidation griefing:
  - close-factor and health predicate checks.
- Insolvency edge:
  - deterministic bad-debt write-off path.

## Residual risk

- In-pool tick proxy is still manipulable in thin markets.
- Model is conservative but not oracle-grade finality.
