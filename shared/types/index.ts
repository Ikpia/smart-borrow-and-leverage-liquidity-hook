export type Address = `0x${string}`;

export interface DeploymentAddresses {
  hook: Address;
  vault: Address;
  market: Address;
  riskManager: Address;
  router: Address;
  liquidation: Address;
  flashModule: Address;
  flashProvider: Address;
  token0: Address;
  token1: Address;
}

export interface RiskSnapshot {
  rawValueQuote: bigint;
  collateralValueQuote: bigint;
  debtQuote: bigint;
  maxBorrowQuote: bigint;
  liquidationValueQuote: bigint;
  adjustedLtvBps: number;
  adjustedLiquidationLtvBps: number;
  adjustedCollateralFactorBps: number;
  riskPenaltyBps: number;
  healthFactorWad: bigint;
}
