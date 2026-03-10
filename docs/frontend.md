# Frontend

The frontend lives in `/frontend` and provides a leverage console for:

- opening position,
- borrow + reinvest,
- repay + unwind,
- health / LTV / debt snapshots,
- stress simulation controls.

## Run

```bash
make frontend
```

The UI reads deployment addresses from a simple config object in `frontend/app.js`.
