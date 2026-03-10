# Demo Flow

Judge-focused flow:

1. Deploy protocol stack and seed market liquidity.
2. User opens collateralized LP-aligned position.
3. User borrows and reinvests in one tx.
4. Show metrics before/after:
   - debt,
   - max borrow,
   - health factor,
   - effective leveraged liquidity.
5. Apply stress (tick/depth/volatility shift).
6. Show either:
   - repay + unwind path, or
   - permissionless liquidation path.

## Commands

- `make demo-local`
- `make demo-leverage`
- `make demo-liquidate`
- `make demo-all`
- `make demo-testnet`
