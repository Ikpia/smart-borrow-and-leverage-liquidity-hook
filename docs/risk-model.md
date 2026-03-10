# Risk Model

This implementation uses **Option A: In-Pool Price Proxy + Haircuts**.

## 1) Raw collateral value

Borrow asset value is computed from current pool tick.

- If borrow asset is token1:
  - `rawValue = collateral1 + convert0To1(collateral0, tick)`
- If borrow asset is token0:
  - `rawValue = collateral0 + convert1To0(collateral1, tick)`

Price conversion uses `TickMath + FullMath` from v4-core.

## 2) Dynamic risk penalty

`riskPenaltyBps = volPenalty + depthPenalty + distancePenalty + rangePenalty`, capped.

Inputs:

- `volPenalty`: EWMA(abs tick delta) from hook.
- `depthPenalty`: current in-range liquidity vs target depth.
- `distancePenalty`: |activeTick - rangeCenter|.
- `rangePenalty`: narrow range penalty when width < configured minimum.

## 3) Dynamic LTV and collateral factor

- `adjustedLtv = max(minLtv, baseLtv - riskPenalty)`
- `adjustedCollateralFactor = max(minCollateralFactor, baseCollateralFactor - riskPenalty/2)`
- `adjustedLiquidationLtv` is penalized but always strictly above `adjustedLtv`.

Then:

- `collateralValue = rawValue * adjustedCollateralFactor / 10_000`
- `maxBorrow = collateralValue * adjustedLtv / 10_000`
- `liquidationValue = collateralValue * adjustedLiquidationLtv / 10_000`
- `healthFactor = liquidationValue / debt`

## Worked example

Assume:

- `rawValue = 280,000`
- `adjustedCollateralFactor = 7,000 bps`
- `adjustedLtv = 4,500 bps`
- `adjustedLiquidationLtv = 5,000 bps`

Then:

- `collateralValue = 196,000`
- `maxBorrow = 88,200`
- `liquidationValue = 98,000`
- if debt is `90,000`, health factor is `1.088...` (healthy)
