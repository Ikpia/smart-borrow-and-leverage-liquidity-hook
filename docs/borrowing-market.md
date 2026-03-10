# Borrowing Market

## Accounting model

- Debt uses a global `borrowIndexRay` (1e27 fixed-point).
- Borrowers store scaled debt: `scaledDebt`.
- Actual debt: `scaledDebt * borrowIndex / RAY`.

This yields O(1) interest accrual and O(1) borrow/repay updates.

## Rate model

Utilization kink model:

- `util = debt / (cash + debt)`
- if `util <= kink`:
  - `rate = base + slope1 * util / kink`
- else:
  - `rate = base + slope1 + slope2 * (util-kink)/(1-kink)`

Rates are annualized in ray and converted to per-second for accrual.

## Supplier side

- Suppliers receive shares.
- Share value tracks `totalAssets`.
- `totalAssets = cash + debt - reserves - badDebt`.

## Risk reserves

A reserve factor diverts part of accrued interest into protocol reserves.
