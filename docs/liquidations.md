# Liquidations

## Trigger

A position is liquidatable when:

- `debt > liquidationValue`.

## Execution

`LiquidationModule.liquidate(positionId, repayAmount, ...)`:

1. verifies unhealthy state,
2. enforces close-factor cap,
3. repays debt into `BorrowingMarket`,
4. seizes vault collateral + leveraged liquidity share with bonus,
5. optionally writes off bad debt if collateral is exhausted.

## Incentives

- liquidator receives seized collateral plus configured bonus,
- liquidation is permissionless.

## Bad debt rule

- reserves are consumed first,
- any uncovered amount increments `badDebt` (socialized loss accounting).
