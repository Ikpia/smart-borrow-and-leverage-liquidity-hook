# Frontend Leverage Console

Static console for protocol operations and judge demos.

## Configure

Edit `frontend/app.js` `CONFIG` values with deployed addresses:

- `router`
- `riskManager`
- `liquidation`
- `metricsHook` (mock metrics hook for stress simulation)

Also set PoolKey placeholders in `openPosition()`.

## Run

From repo root:

```bash
make frontend
```

Then open `http://127.0.0.1:4173/frontend/`.
