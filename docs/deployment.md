# Deployment

## Local (Anvil)

1. Start anvil:

```bash
anvil
```

2. Deploy protocol + local demo scaffolding:

```bash
forge script script/deploy/DeployProtocol.s.sol:DeployProtocolScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Testnet

Use Unichain Sepolia (`chainId=1301`):

```bash
./scripts/deploy-unichain.sh
```

## Environment

See `.env.example` for required variables.

## Address output

Deployment scripts print addresses for:

- hook
- vault
- market
- risk manager
- router
- liquidation module
- flash module

`scripts/deploy-unichain.sh` also persists these to `.env` as:

- `DEPLOYED_TOKEN0_ADDRESS`
- `DEPLOYED_TOKEN1_ADDRESS`
- `DEPLOYED_HOOK_ADDRESS`
- `DEPLOYED_VAULT_ADDRESS`
- `DEPLOYED_MARKET_ADDRESS`
- `DEPLOYED_RISK_MANAGER_ADDRESS`
- `DEPLOYED_ROUTER_ADDRESS`
- `DEPLOYED_LIQUIDATION_MODULE_ADDRESS`
- `DEPLOYED_FLASH_PROVIDER_ADDRESS`
- `DEPLOYED_FLASH_MODULE_ADDRESS`

and prints tx hash + explorer URL for every transaction in the deployment broadcast.

## Latest Unichain Sepolia deployment snapshot

- Hook: `0x2d2a64dcd864ba1c83dd634a8c19c4f695db10c0`
- Vault: `0xdd008a1209bf0400c3e7c0b5a4d23e691ee43990`
- Market: `0xb4b2d15ebec35e21e2fbce3845bff476082cc628`
- RiskManager: `0x70df6c59673adaee5ac1354f1051bc6a232a3c53`
- Router: `0x3642fa7e78acfabf2851619acdb92ac560efc746`
- LiquidationModule: `0x9148f61ad2d5cef6a7c43c6c951a816475cd1bfe`
- FlashLeverageModule: `0x23856a24fb7e7aaca2ed7fef96f269269b4bd245`
- Broadcast record:
  - `broadcast/DeployProtocolUnichain.s.sol/1301/run-latest.json`
