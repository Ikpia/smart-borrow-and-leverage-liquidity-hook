// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {LPVault} from "../../src/LPVault.sol";
import {BorrowingMarket} from "../../src/markets/BorrowingMarket.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {LiquidationModule} from "../../src/modules/LiquidationModule.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract LeverageLifecycleIntegrationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;
    PoolId internal poolId;

    LeverageLiquidityHook internal hook;
    LPVault internal vault;
    BorrowingMarket internal market;
    RiskManager internal riskManager;
    LeverageRouter internal router;
    LiquidationModule internal liquidation;

    address internal liquidator = address(0xBEEF);

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x6666 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("LeverageLiquidityHook.sol:LeverageLiquidityHook", constructorArgs, flags);
        hook = LeverageLiquidityHook(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, hook);
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        _seedUniswapPool();

        vault = new LPVault(address(this));
        market = new BorrowingMarket(Currency.unwrap(currency1), address(this));
        riskManager = new RiskManager(address(this), vault, market, hook);
        router = new LeverageRouter(vault, market, riskManager);
        liquidation = new LiquidationModule(address(this), vault, market, riskManager);

        vault.setOperator(address(router), true);
        vault.setLiquidationModule(address(liquidation));

        market.setBorrower(address(router), true);
        market.setRepayer(address(router), true);
        market.setRepayer(address(liquidation), true);
        market.setLiquidationModule(address(liquidation));

        IERC20(Currency.unwrap(currency1)).approve(address(market), type(uint256).max);
        market.supply(1_000_000 ether, address(this));

        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);

        IERC20(Currency.unwrap(currency1)).transfer(liquidator, 200_000 ether);
        vm.prank(liquidator);
        IERC20(Currency.unwrap(currency1)).approve(address(market), type(uint256).max);

        DataTypes.PoolRiskConfig memory cfg = DataTypes.PoolRiskConfig({
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
        riskManager.setPoolRiskConfig(PoolId.unwrap(poolId), cfg);
    }

    function testLifecycleBorrowReinvestRepayAndUnwind() public {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -900,
            tickUpper: 900,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: 40_000 ether,
            leveragedLiquidity: 15_000,
            minHealthFactorWad: 1e18
        });

        uint256 positionId = router.openBorrowAndReinvest(p);

        assertEq(market.debtOf(positionId), 40_000 ether);
        assertGe(riskManager.healthFactorWad(positionId), 1e18);

        vm.warp(block.timestamp + 2 days);

        router.repayAndUnwind(positionId, 20_000 ether, 10_000 ether, 5_000 ether, 2_000);

        assertLt(market.debtOf(positionId), 40_000 ether);
        assertGe(riskManager.healthFactorWad(positionId), 1e18);
    }

    function testLifecycleLiquidationAfterStressMove() public {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -300,
            tickUpper: 300,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: 60_000 ether,
            leveragedLiquidity: 30_000,
            minHealthFactorWad: 1e18
        });

        uint256 positionId = router.openBorrowAndReinvest(p);

        _stressMovePrice();
        riskManager.setPoolRiskConfig(PoolId.unwrap(poolId), _tightRiskConfig());

        assertTrue(riskManager.isLiquidatable(positionId));

        vm.prank(liquidator);
        liquidation.liquidate(positionId, 70_000 ether, 0, 0);

        assertLt(market.debtOf(positionId), 60_000 ether);
    }

    function _seedUniswapPool() internal {
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 400_000;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey,
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

    function _stressMovePrice() internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: 100_000 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        swapRouter.swapExactTokensForTokens({
            amountIn: 80_000 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _tightRiskConfig() internal pure returns (DataTypes.PoolRiskConfig memory cfg) {
        cfg = DataTypes.PoolRiskConfig({
            enabled: true,
            stablePool: false,
            baseLtvBps: 4_500,
            liquidationLtvBps: 5_000,
            minLtvBps: 1_500,
            baseCollateralFactorBps: 7_000,
            minCollateralFactorBps: 5_000,
            maxVolatilityPenaltyBps: 1_200,
            maxDepthPenaltyBps: 700,
            maxDistancePenaltyBps: 700,
            maxRangePenaltyBps: 600,
            targetDepthLiquidity: 150_000,
            maxVolatilityEwma: 1_000,
            maxCenterDistance: 1_200,
            minRangeWidth: 1_200
        });
    }
}
