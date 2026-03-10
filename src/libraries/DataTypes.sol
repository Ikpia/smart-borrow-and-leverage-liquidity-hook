// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library DataTypes {
    uint16 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;

    struct Position {
        address owner;
        bytes32 poolId;
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint128 baseLiquidity;
        uint128 leveragedLiquidity;
        uint256 collateral0;
        uint256 collateral1;
        bool active;
    }

    struct PoolMetrics {
        int24 currentTick;
        uint24 volatilityEwma;
        uint128 depthLiquidity;
        uint32 lastUpdate;
    }

    struct PoolRiskConfig {
        bool enabled;
        bool stablePool;
        uint16 baseLtvBps;
        uint16 liquidationLtvBps;
        uint16 minLtvBps;
        uint16 baseCollateralFactorBps;
        uint16 minCollateralFactorBps;
        uint16 maxVolatilityPenaltyBps;
        uint16 maxDepthPenaltyBps;
        uint16 maxDistancePenaltyBps;
        uint16 maxRangePenaltyBps;
        uint32 targetDepthLiquidity;
        uint24 maxVolatilityEwma;
        int24 maxCenterDistance;
        int24 minRangeWidth;
    }

    struct RiskSnapshot {
        uint256 rawValueQuote;
        uint256 collateralValueQuote;
        uint256 debtQuote;
        uint256 maxBorrowQuote;
        uint256 liquidationValueQuote;
        uint16 adjustedLtvBps;
        uint16 adjustedLiquidationLtvBps;
        uint16 adjustedCollateralFactorBps;
        uint16 riskPenaltyBps;
        uint256 healthFactorWad;
    }
}
