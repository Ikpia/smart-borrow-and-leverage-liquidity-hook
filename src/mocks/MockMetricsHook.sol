// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DataTypes} from "../libraries/DataTypes.sol";
import {ILeverageLiquidityHook} from "../interfaces/ILeverageLiquidityHook.sol";

contract MockMetricsHook is ILeverageLiquidityHook {
    mapping(bytes32 => DataTypes.PoolMetrics) public metrics;

    function setPoolMetrics(bytes32 poolId, int24 currentTick, uint24 volatilityEwma, uint128 depthLiquidity) external {
        metrics[poolId] = DataTypes.PoolMetrics({
            currentTick: currentTick,
            volatilityEwma: volatilityEwma,
            depthLiquidity: depthLiquidity,
            lastUpdate: uint32(block.timestamp)
        });
    }

    function getPoolMetrics(bytes32 poolId) external view returns (DataTypes.PoolMetrics memory) {
        return metrics[poolId];
    }
}
