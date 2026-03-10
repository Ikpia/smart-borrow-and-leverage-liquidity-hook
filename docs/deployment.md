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

Use Base Sepolia (preferred) or another supported chain:

```bash
forge script script/deploy/DeployProtocol.s.sol:DeployProtocolScript \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
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
