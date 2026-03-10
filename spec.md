# Specification: Smart Borrow & Leveraged Liquidity Hook

## 1. Mission

A deterministic, oracle-minimal capital efficiency primitive that allows users to borrow against LP-aligned collateral and reinvest borrowed notional to deepen effective liquidity.

## 2. Non-goals

- No off-chain keepers required for protocol correctness.
- No claims of perfect manipulation resistance.
- No dependency on external price oracles in core solvency logic.

## 3. Components

### 3.1 LeverageLiquidityHook

Responsibilities:

- implement swap-related v4 hook entry points,
- enforce PoolManager-only hook calls via `BaseHook`,
- maintain per-pool metrics:
  - current tick,
  - EWMA volatility proxy,
  - in-range depth proxy.

### 3.2 LPVault

Responsibilities:

- account for per-position collateral and leverage metadata,
- gate write operations to approved operators,
- transfer seized collateral during liquidation.

### 3.3 BorrowingMarket

Responsibilities:

- pooled suppliers / borrowers,
- O(1) scaled debt accounting,
- utilization-kink rate model,
- reserve and bad-debt tracking.

### 3.4 RiskManager

Responsibilities:

- deterministic collateral valuation from in-pool tick,
- dynamic LTV and collateral factor,
- health / liquidation predicates.

### 3.5 LeverageRouter

Responsibilities:

- atomic user flows:
  - open + borrow + reinvest,
  - borrow more,
  - repay + unwind.

### 3.6 LiquidationModule

Responsibilities:

- permissionless unhealthy-position liquidation,
- close-factor + bonus enforcement,
- deterministic bad-debt write-off path.

### 3.7 FlashLeverageModule (optional path)

Responsibilities:

- bounded flash-assisted leverage,
- active tick distance checks,
- enforced atomic flash repayment.

## 4. Core formulas

Let `BPS = 10_000`, `WAD = 1e18`, `RAY = 1e27`.

### 4.1 Interest

- borrower scaled debt: `scaledDebt_i`
- global index: `borrowIndex`
- debt: `debt_i = scaledDebt_i * borrowIndex / RAY`

Accrual:

- `borrowIndex' = borrowIndex * (RAY + ratePerSecond * dt) / RAY`

### 4.2 Risk penalties

`penalty = vol + depth + distance + range`

where each term is bounded and normalized by configured caps.

### 4.3 Dynamic limits

- `adjLtv = max(minLtv, baseLtv - penalty)`
- `adjCF = max(minCF, baseCF - penalty/2)`
- `adjLiqLtv` remains strictly greater than `adjLtv`.

### 4.4 Solvency

- `collateralValue = rawValue * adjCF / BPS`
- `maxBorrow = collateralValue * adjLtv / BPS`
- `liquidationValue = collateralValue * adjLiqLtv / BPS`
- `health = liquidationValue * WAD / debt`

Liquidatable iff `debt > liquidationValue`.

## 5. User flows

### 5.1 Borrow against LP-aligned collateral

1. user deposits collateral through router,
2. vault opens position,
3. risk manager validates borrow bounds,
4. market issues debt.

### 5.2 Leveraged reinvest

1. borrowed asset is sent into vault accounting,
2. leveraged liquidity metadata is incremented,
3. post-state health factor enforced.

### 5.3 Repay and unwind

1. user repays debt,
2. vault returns collateral per requested unwind,
3. remaining debt must stay healthy.

### 5.4 Liquidation

1. liquidator repays bounded debt fraction,
2. vault collateral seized with bonus,
3. if collateral exhausted, bad debt write-off applies.

## 6. Access control matrix

- Hook entrypoints: PoolManager only.
- Vault mutation: authorized operators.
- BorrowingMarket borrow/repay/write-off: authorized modules.
- Risk config updates: owner.

## 7. Security posture

Covered in detail in [docs/security.md](./docs/security.md).

## 8. Test requirements

Implemented suites:

- unit,
- fuzz,
- invariants,
- integration lifecycle.

See [docs/testing.md](./docs/testing.md).
