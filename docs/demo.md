# Demo Flow

This repo ships a deterministic demo runner that proves the full lifecycle with on-chain transactions and explorer links.

## End-to-end phases

1. Preflight:
   - load `.env`,
   - verify RPC/keys,
   - verify chain id (`1301` for Unichain Sepolia).
2. Deploy phase (`scripts/deploy-unichain.sh`):
   - deploys mock tokens + hook + vault + market + risk + router + liquidation + flash modules,
   - seeds `BorrowingMarket` supply liquidity,
   - configures router/operator/repayer permissions,
   - persists deployed addresses into `.env`.
3. User perspective phase:
   - user mints demo collateral tokens,
   - user approves router + market,
   - user executes `openBorrowAndReinvest` (deposit LP collateral + borrow + reinvest in one atomic flow),
   - script logs position id, debt, health factor, max borrow.
4. Safe unwind phase:
   - user executes partial `repayAndUnwind`,
   - user executes `repayAllAndWithdraw`,
   - script logs debt and risk state after each step.
5. Liquidation proof phase:
   - user opens a second leveraged position,
   - liquidator funds borrow asset and approves market,
   - hook metrics are synced,
   - owner tightens risk config,
   - liquidator executes permissionless `liquidate`,
   - script logs post-liquidation debt and health factor.
6. Evidence phase:
   - every tx hash is printed,
   - every tx gets an explorer URL,
   - deployed contract addresses get explorer URLs,
   - run JSON path is printed (`broadcast/.../run-latest.json`).

## Commands

- Full lifecycle on Unichain Sepolia:
  - `make demo-testnet`
  - or `./scripts/demo-testnet.sh all`
- Leverage + repay path only:
  - `./scripts/demo-testnet.sh leverage`
- Liquidation path only:
  - `./scripts/demo-testnet.sh liquidate`
- Local Anvil variants:
  - `make demo-local`
  - `make demo-leverage`
  - `make demo-liquidate`

## Output artifacts

- Deployment log: `logs/deploy-unichain-*.log`
- Demo log: `logs/demo-testnet-*.log`
- Foundry broadcast tx records:
  - `broadcast/script/deploy/DeployProtocol.s.sol/<chainId>/run-latest.json`
  - `broadcast/script/demo/DemoUsingDeployment.s.sol/<chainId>/run-latest.json`
