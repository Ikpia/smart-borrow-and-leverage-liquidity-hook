# Architecture

## System boundaries

- Uniswap v4 provides pool state and swap hooks.
- Hook-derived metrics are consumed by the risk engine.
- Core credit accounting is internal to this repo.

## State ownership

- `LPVault`: owner, collateral balances, leverage metadata per position.
- `BorrowingMarket`: supplier shares, scaled debt, global index, reserves, bad debt.
- `RiskManager`: per-pool risk config and deterministic valuation logic.
- `LeverageLiquidityHook`: per-pool tick/depth/volatility snapshots.

## Data flow

1. User opens collateralized position through `LeverageRouter`.
2. `BorrowingMarket` lends borrow asset (token) to the vault for reinvest.
3. `LPVault` updates leveraged collateral/liquidity state.
4. `RiskManager` continuously computes max borrow / health from vault state + hook metrics.
5. `LiquidationModule` repays debt and seizes collateral when unhealthy.

## Determinism constraints

- No loop over all users in any critical state transition.
- Interest updates are index-based O(1).
- Risk inputs are on-chain only (pool tick/liquidity + in-position geometry).
