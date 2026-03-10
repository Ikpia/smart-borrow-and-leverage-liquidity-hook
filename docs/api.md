# API Summary

## LeverageRouter

- `openBorrowAndReinvest(OpenPositionParams)`
- `borrowAndReinvest(positionId, borrowAmount, addLiquidity, minHealth)`
- `repayAndUnwind(positionId, repayAmount, withdraw0, withdraw1, reduceLiquidity)`
- `repayAllAndWithdraw(positionId)`

## RiskManager

- `snapshot(positionId)`
- `maxBorrowable(positionId)`
- `canBorrow(positionId, additionalDebt)`
- `isHealthy(positionId)`
- `isLiquidatable(positionId)`

## BorrowingMarket

- `supply(assets, onBehalfOf)` / `withdraw(shares, receiver)`
- `borrowFor(positionId, receiver, amount)`
- `repayFor(positionId, payer, amount)`
- `forgiveBadDebt(positionId)`

## LPVault

- `openPosition(...)`
- `increaseLeverage(...)`
- `reducePosition(...)`
- `seizeForLiquidation(...)`
