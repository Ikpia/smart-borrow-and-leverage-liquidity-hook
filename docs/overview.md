# Overview

Smart Borrow & Leveraged Liquidity Hook is a deterministic capital-efficiency primitive built on Uniswap v4:

- users post LP-aligned collateral,
- borrow against that collateral,
- reinvest borrowed capital into the same market,
- maintain solvency through deterministic risk controls and permissionless liquidation.

## Core guarantees

- No keepers, bots, or reactive off-chain dependencies are required for correctness.
- Borrow limits and liquidation checks are fully on-chain and deterministic.
- Interest accrual is O(1) and monotonic using an index model.
- Liquidation is permissionless and bounded.
- Optional flash-leverage is capped and enforces atomic flash repayment.

## Components

- `LeverageLiquidityHook`: Uniswap v4 hook for pool metrics (tick/depth/volatility proxy).
- `LPVault`: custody + per-position collateral/liquidity accounting.
- `BorrowingMarket`: pooled lending with utilization-kink rates.
- `RiskManager`: dynamic LTV + health factor engine.
- `LeverageRouter`: one-click leverage and unwind flows.
- `LiquidationModule`: permissionless liquidations and bad-debt write-off path.
- `FlashLeverageModule` + `MockFlashLoanProvider`: optional bounded flash path.
