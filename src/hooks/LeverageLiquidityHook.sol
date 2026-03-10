// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {DataTypes} from "../libraries/DataTypes.sol";
import {ILeverageLiquidityHook} from "../interfaces/ILeverageLiquidityHook.sol";

contract LeverageLiquidityHook is BaseHook, ILeverageLiquidityHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    event PoolMetricsUpdated(
        bytes32 indexed poolId,
        int24 currentTick,
        uint24 volatilityEwma,
        uint128 depthLiquidity,
        uint32 lastUpdate
    );

    mapping(PoolId => DataTypes.PoolMetrics) private _poolMetrics;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function getPoolMetrics(bytes32 poolId) external view returns (DataTypes.PoolMetrics memory) {
        return _poolMetrics[PoolId.wrap(poolId)];
    }

    function getPoolMetricsForKey(PoolKey calldata key) external view returns (DataTypes.PoolMetrics memory) {
        return _poolMetrics[key.toId()];
    }

    function syncPool(PoolKey calldata key) external {
        _syncPool(key);
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);
        uint128 depth = poolManager.getLiquidity(poolId);

        _poolMetrics[poolId] = DataTypes.PoolMetrics({
            currentTick: tick == 0 ? currentTick : tick,
            volatilityEwma: 0,
            depthLiquidity: depth,
            lastUpdate: uint32(block.timestamp)
        });

        emit PoolMetricsUpdated(
            PoolId.unwrap(poolId),
            _poolMetrics[poolId].currentTick,
            _poolMetrics[poolId].volatilityEwma,
            depth,
            uint32(block.timestamp)
        );

        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _syncPool(key);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _syncPool(PoolKey calldata key) internal {
        PoolId poolId = key.toId();

        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 depth = poolManager.getLiquidity(poolId);

        DataTypes.PoolMetrics storage m = _poolMetrics[poolId];
        uint24 absDelta = _absTickDelta(m.currentTick, tick);

        if (m.lastUpdate == 0) {
            m.volatilityEwma = absDelta;
        } else {
            // 70/30 EWMA update to damp noisy one-block moves.
            uint256 ewma = (uint256(m.volatilityEwma) * 7) + (uint256(absDelta) * 3);
            m.volatilityEwma = uint24(ewma / 10);
        }

        m.currentTick = tick;
        m.depthLiquidity = depth;
        m.lastUpdate = uint32(block.timestamp);

        emit PoolMetricsUpdated(PoolId.unwrap(poolId), tick, m.volatilityEwma, depth, m.lastUpdate);
    }

    function _absTickDelta(int24 a, int24 b) private pure returns (uint24) {
        int256 delta = int256(a) - int256(b);
        if (delta < 0) delta = -delta;
        return uint24(uint256(delta));
    }
}
