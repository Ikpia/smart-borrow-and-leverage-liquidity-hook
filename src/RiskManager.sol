// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {DataTypes} from "./libraries/DataTypes.sol";
import {ILPVault} from "./interfaces/ILPVault.sol";
import {IBorrowingMarket} from "./interfaces/IBorrowingMarket.sol";
import {ILeverageLiquidityHook} from "./interfaces/ILeverageLiquidityHook.sol";

contract RiskManager is Ownable2Step {
    error InvalidPoolConfig();
    error UnsupportedBorrowAsset();

    event PoolRiskConfigUpdated(bytes32 indexed poolId, DataTypes.PoolRiskConfig config);

    ILPVault public immutable vault;
    IBorrowingMarket public immutable market;
    ILeverageLiquidityHook public immutable hook;
    address public immutable borrowAsset;

    DataTypes.PoolRiskConfig public defaultStableConfig;
    DataTypes.PoolRiskConfig public defaultVolatileConfig;

    mapping(bytes32 => DataTypes.PoolRiskConfig) public poolRiskConfig;

    constructor(address admin, ILPVault vault_, IBorrowingMarket market_, ILeverageLiquidityHook hook_) Ownable(admin) {
        vault = vault_;
        market = market_;
        hook = hook_;
        borrowAsset = market_.borrowToken();

        defaultStableConfig = DataTypes.PoolRiskConfig({
            enabled: true,
            stablePool: true,
            baseLtvBps: 7_500,
            liquidationLtvBps: 8_300,
            minLtvBps: 5_500,
            baseCollateralFactorBps: 9_000,
            minCollateralFactorBps: 8_000,
            maxVolatilityPenaltyBps: 600,
            maxDepthPenaltyBps: 300,
            maxDistancePenaltyBps: 500,
            maxRangePenaltyBps: 400,
            targetDepthLiquidity: 50_000,
            maxVolatilityEwma: 400,
            maxCenterDistance: 600,
            minRangeWidth: 400
        });

        defaultVolatileConfig = DataTypes.PoolRiskConfig({
            enabled: true,
            stablePool: false,
            baseLtvBps: 5_500,
            liquidationLtvBps: 6_500,
            minLtvBps: 3_500,
            baseCollateralFactorBps: 8_000,
            minCollateralFactorBps: 6_800,
            maxVolatilityPenaltyBps: 1_200,
            maxDepthPenaltyBps: 600,
            maxDistancePenaltyBps: 800,
            maxRangePenaltyBps: 700,
            targetDepthLiquidity: 100_000,
            maxVolatilityEwma: 800,
            maxCenterDistance: 1_200,
            minRangeWidth: 1_000
        });
    }

    function setDefaultStableConfig(DataTypes.PoolRiskConfig calldata cfg) external onlyOwner {
        _validateConfig(cfg);
        defaultStableConfig = cfg;
    }

    function setDefaultVolatileConfig(DataTypes.PoolRiskConfig calldata cfg) external onlyOwner {
        _validateConfig(cfg);
        defaultVolatileConfig = cfg;
    }

    function setPoolRiskConfig(bytes32 poolId, DataTypes.PoolRiskConfig calldata cfg) external onlyOwner {
        _validateConfig(cfg);
        poolRiskConfig[poolId] = cfg;
        emit PoolRiskConfigUpdated(poolId, cfg);
    }

    function snapshot(uint256 positionId) public view returns (DataTypes.RiskSnapshot memory s) {
        DataTypes.Position memory p = vault.position(positionId);
        if (!p.active) {
            return s;
        }

        DataTypes.PoolRiskConfig memory cfg = _configForPool(p.poolId);
        DataTypes.PoolMetrics memory m = hook.getPoolMetrics(p.poolId);

        uint16 penalty = _riskPenalty(cfg, p, m);

        uint16 adjustedLtv = _applyPenaltyFloor(cfg.baseLtvBps, cfg.minLtvBps, penalty);
        uint16 adjustedLiqLtv = _adjustedLiquidationLtv(cfg, penalty, adjustedLtv);
        uint16 adjustedCollateralFactor = _applyPenaltyFloor(cfg.baseCollateralFactorBps, cfg.minCollateralFactorBps, penalty / 2);

        uint256 rawValue = _rawValueInBorrowAsset(p, m.currentTick);
        uint256 collateralValue = (rawValue * adjustedCollateralFactor) / DataTypes.BPS;
        uint256 maxBorrow = (collateralValue * adjustedLtv) / DataTypes.BPS;
        uint256 liquidationValue = (collateralValue * adjustedLiqLtv) / DataTypes.BPS;

        uint256 debt = market.debtOf(positionId);
        uint256 health = debt == 0 ? type(uint256).max : (liquidationValue * DataTypes.WAD) / debt;

        s = DataTypes.RiskSnapshot({
            rawValueQuote: rawValue,
            collateralValueQuote: collateralValue,
            debtQuote: debt,
            maxBorrowQuote: maxBorrow,
            liquidationValueQuote: liquidationValue,
            adjustedLtvBps: adjustedLtv,
            adjustedLiquidationLtvBps: adjustedLiqLtv,
            adjustedCollateralFactorBps: adjustedCollateralFactor,
            riskPenaltyBps: penalty,
            healthFactorWad: health
        });
    }

    function maxBorrowable(uint256 positionId) external view returns (uint256) {
        DataTypes.RiskSnapshot memory s = snapshot(positionId);
        if (s.debtQuote >= s.maxBorrowQuote) return 0;
        return s.maxBorrowQuote - s.debtQuote;
    }

    function canBorrow(uint256 positionId, uint256 additionalDebt) external view returns (bool) {
        DataTypes.RiskSnapshot memory s = snapshot(positionId);
        return (s.debtQuote + additionalDebt) <= s.maxBorrowQuote;
    }

    function healthFactorWad(uint256 positionId) external view returns (uint256) {
        return snapshot(positionId).healthFactorWad;
    }

    function isHealthy(uint256 positionId) public view returns (bool) {
        DataTypes.RiskSnapshot memory s = snapshot(positionId);
        return s.debtQuote <= s.liquidationValueQuote;
    }

    function isLiquidatable(uint256 positionId) external view returns (bool) {
        DataTypes.RiskSnapshot memory s = snapshot(positionId);
        return s.debtQuote > s.liquidationValueQuote;
    }

    function _configForPool(bytes32 poolId) internal view returns (DataTypes.PoolRiskConfig memory cfg) {
        cfg = poolRiskConfig[poolId];
        if (!cfg.enabled) {
            cfg = defaultVolatileConfig;
        }
    }

    function _riskPenalty(DataTypes.PoolRiskConfig memory cfg, DataTypes.Position memory p, DataTypes.PoolMetrics memory m)
        internal
        pure
        returns (uint16)
    {
        uint16 volPenalty = _linearPenalty(m.volatilityEwma, cfg.maxVolatilityEwma, cfg.maxVolatilityPenaltyBps);

        uint16 depthPenalty;
        if (cfg.targetDepthLiquidity > 0 && m.depthLiquidity < cfg.targetDepthLiquidity) {
            depthPenalty = uint16(
                (uint256(cfg.maxDepthPenaltyBps) * (cfg.targetDepthLiquidity - uint32(m.depthLiquidity)))
                    / cfg.targetDepthLiquidity
            );
        }

        uint24 width = _rangeWidth(p.tickLower, p.tickUpper);
        uint16 rangePenalty;
        if (cfg.minRangeWidth > 0 && width < uint24(uint256(uint24(cfg.minRangeWidth)))) {
            rangePenalty = uint16(
                (uint256(cfg.maxRangePenaltyBps) * (uint24(uint24(cfg.minRangeWidth)) - width)) / uint24(uint24(cfg.minRangeWidth))
            );
        }

        int24 center = int24((int256(p.tickLower) + int256(p.tickUpper)) / 2);
        uint24 distance = _absTickDiff(m.currentTick, center);
        uint16 distancePenalty =
            _linearPenalty(distance, uint24(uint256(uint24(cfg.maxCenterDistance))), cfg.maxDistancePenaltyBps);

        uint256 sum = uint256(volPenalty) + uint256(depthPenalty) + uint256(rangePenalty) + uint256(distancePenalty);

        uint16 cap = cfg.baseLtvBps > cfg.minLtvBps ? cfg.baseLtvBps - cfg.minLtvBps : 0;
        if (sum > cap) sum = cap;

        return uint16(sum);
    }

    function _rawValueInBorrowAsset(DataTypes.Position memory p, int24 tick) internal view returns (uint256) {
        if (borrowAsset == p.token1) {
            return p.collateral1 + _convert0To1(p.collateral0, tick);
        }
        if (borrowAsset == p.token0) {
            return p.collateral0 + _convert1To0(p.collateral1, tick);
        }
        revert UnsupportedBorrowAsset();
    }

    function _convert0To1(uint256 amount0, int24 tick) internal pure returns (uint256) {
        if (amount0 == 0) return 0;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        return FullMath.mulDiv(amount0, priceX96, FixedPoint96.Q96);
    }

    function _convert1To0(uint256 amount1, int24 tick) internal pure returns (uint256) {
        if (amount1 == 0) return 0;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, priceX96);
    }

    function _adjustedLiquidationLtv(DataTypes.PoolRiskConfig memory cfg, uint16 penalty, uint16 adjustedLtv)
        internal
        pure
        returns (uint16)
    {
        uint16 liqPenalty = penalty / 2;
        uint16 liq = cfg.liquidationLtvBps > liqPenalty ? cfg.liquidationLtvBps - liqPenalty : adjustedLtv;

        if (liq <= adjustedLtv) {
            liq = adjustedLtv + 1;
        }

        if (liq > DataTypes.BPS) {
            liq = DataTypes.BPS;
        }

        return liq;
    }

    function _applyPenaltyFloor(uint16 baseValue, uint16 floorValue, uint16 penalty) internal pure returns (uint16) {
        uint16 adjusted = baseValue > penalty ? baseValue - penalty : floorValue;
        if (adjusted < floorValue) adjusted = floorValue;
        return adjusted;
    }

    function _linearPenalty(uint24 value, uint24 maxValue, uint16 maxPenalty) internal pure returns (uint16) {
        if (value == 0 || maxValue == 0 || maxPenalty == 0) return 0;
        if (value >= maxValue) return maxPenalty;
        return uint16((uint256(maxPenalty) * value) / maxValue);
    }

    function _rangeWidth(int24 tickLower, int24 tickUpper) internal pure returns (uint24) {
        if (tickUpper <= tickLower) return 0;
        return uint24(uint256(int256(tickUpper) - int256(tickLower)));
    }

    function _absTickDiff(int24 a, int24 b) internal pure returns (uint24) {
        int256 diff = int256(a) - int256(b);
        if (diff < 0) diff = -diff;
        return uint24(uint256(diff));
    }

    function _validateConfig(DataTypes.PoolRiskConfig calldata cfg) internal pure {
        if (!cfg.enabled) revert InvalidPoolConfig();
        if (cfg.baseLtvBps == 0 || cfg.baseLtvBps >= DataTypes.BPS) revert InvalidPoolConfig();
        if (cfg.liquidationLtvBps <= cfg.baseLtvBps || cfg.liquidationLtvBps > DataTypes.BPS) {
            revert InvalidPoolConfig();
        }
        if (cfg.minLtvBps > cfg.baseLtvBps) revert InvalidPoolConfig();
        if (cfg.minCollateralFactorBps > cfg.baseCollateralFactorBps || cfg.baseCollateralFactorBps > DataTypes.BPS) {
            revert InvalidPoolConfig();
        }
        if (cfg.maxVolatilityPenaltyBps + cfg.maxDepthPenaltyBps + cfg.maxDistancePenaltyBps + cfg.maxRangePenaltyBps
            > cfg.baseLtvBps)
        {
            revert InvalidPoolConfig();
        }
    }
}
