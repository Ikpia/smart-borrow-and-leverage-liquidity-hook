// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";

import {LeverageLiquidityHook} from "../../src/hooks/LeverageLiquidityHook.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract LeverageLiquidityHookUnitTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;
    PoolId internal poolId;
    LeverageLiquidityHook internal hook;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags =
            address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x7777 << 144));
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("LeverageLiquidityHook.sol:LeverageLiquidityHook", constructorArgs, flags);
        hook = LeverageLiquidityHook(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        _seedLiquidity(poolKey);
    }

    function testHookPermissionsAndPoolMetricGetters() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeInitialize);
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);

        bytes32 id = PoolId.unwrap(poolId);
        DataTypes.PoolMetrics memory byId = hook.getPoolMetrics(id);
        DataTypes.PoolMetrics memory byKey = hook.getPoolMetricsForKey(poolKey);

        assertEq(byId.currentTick, byKey.currentTick);
        assertEq(byId.depthLiquidity, byKey.depthLiquidity);
        assertGt(byId.lastUpdate, 0);
    }

    function testSyncPoolManualResetHitsBootstrapBranch() public {
        // mapping(PoolId => PoolMetrics) is the first storage slot in this hook contract.
        bytes32 mappingSlot = keccak256(abi.encode(PoolId.unwrap(poolId), uint256(0)));
        vm.store(address(hook), mappingSlot, bytes32(0));

        hook.syncPool(poolKey);
        DataTypes.PoolMetrics memory m = hook.getPoolMetrics(PoolId.unwrap(poolId));

        assertGt(m.lastUpdate, 0);
        assertGt(m.depthLiquidity, 0);
    }

    function testAfterSwapSyncsAndTracksEwmaBothDirections() public {
        DataTypes.PoolMetrics memory beforeMetrics = hook.getPoolMetrics(PoolId.unwrap(poolId));

        swapRouter.swapExactTokensForTokens({
            amountIn: 10_000 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        DataTypes.PoolMetrics memory afterFirst = hook.getPoolMetrics(PoolId.unwrap(poolId));
        assertGt(afterFirst.volatilityEwma, beforeMetrics.volatilityEwma);

        swapRouter.swapExactTokensForTokens({
            amountIn: 8_000 ether,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        DataTypes.PoolMetrics memory afterSecond = hook.getPoolMetrics(PoolId.unwrap(poolId));
        assertGt(afterSecond.lastUpdate, 0);
    }

    function testAfterInitializeNonZeroTickPath() public {
        (Currency c0, Currency c1) = deployCurrencyPair();
        PoolKey memory key2 = PoolKey(c0, c1, 3000, 60, IHooks(hook));
        int24 nonZeroTick = 120;
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(nonZeroTick);

        poolManager.initialize(key2, sqrtPrice);

        DataTypes.PoolMetrics memory m = hook.getPoolMetrics(PoolId.unwrap(key2.toId()));
        assertEq(m.currentTick, nonZeroTick);
    }

    function _seedLiquidity(PoolKey memory key) internal {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 400_000;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }
}
