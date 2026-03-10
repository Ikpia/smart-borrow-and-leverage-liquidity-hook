// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DataTypes} from "../libraries/DataTypes.sol";

interface ILeverageLiquidityHook {
    function getPoolMetrics(bytes32 poolId) external view returns (DataTypes.PoolMetrics memory);
}
