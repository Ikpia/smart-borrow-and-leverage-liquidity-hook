// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {MockToken} from "../../src/mocks/MockToken.sol";
import {MockMetricsHook} from "../../src/mocks/MockMetricsHook.sol";
import {MockFlashLoanProvider} from "../../src/mocks/MockFlashLoanProvider.sol";

import {LPVault} from "../../src/LPVault.sol";
import {BorrowingMarket} from "../../src/markets/BorrowingMarket.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {LiquidationModule} from "../../src/modules/LiquidationModule.sol";
import {FlashLeverageModule} from "../../src/modules/FlashLeverageModule.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

abstract contract ProtocolFixture is Test {
    using PoolIdLibrary for PoolKey;

    address internal admin = address(0xA11CE);
    address internal supplier = address(0xB0B);
    address internal user = address(0xCAFE);
    address internal liquidator = address(0xD00D);

    MockToken public token0;
    MockToken public token1;

    MockMetricsHook public metricsHook;
    MockFlashLoanProvider public flashProvider;

    LPVault public vault;
    BorrowingMarket public market;
    RiskManager public riskManager;
    LeverageRouter public router;
    LiquidationModule public liquidation;
    FlashLeverageModule public flashModule;

    PoolKey public poolKey;
    bytes32 public poolId;

    function setUpFixture() internal {
        token0 = new MockToken("Token0", "TK0", 18);
        token1 = new MockToken("Token1", "TK1", 18);

        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        metricsHook = new MockMetricsHook();

        vm.prank(admin);
        vault = new LPVault(admin);

        vm.prank(admin);
        market = new BorrowingMarket(address(token1), admin);

        vm.prank(admin);
        riskManager = new RiskManager(admin, vault, market, metricsHook);

        router = new LeverageRouter(vault, market, riskManager);

        vm.prank(admin);
        liquidation = new LiquidationModule(admin, vault, market, riskManager);

        vm.prank(admin);
        flashProvider = new MockFlashLoanProvider(admin);

        vm.prank(admin);
        flashModule = new FlashLeverageModule(admin, vault, market, riskManager, metricsHook, flashProvider, 500_000 ether);

        vm.startPrank(admin);
        vault.setOperator(address(router), true);
        vault.setOperator(address(flashModule), true);
        vault.setLiquidationModule(address(liquidation));

        market.setBorrower(address(router), true);
        market.setBorrower(address(flashModule), true);
        market.setRepayer(address(router), true);
        market.setRepayer(address(liquidation), true);
        market.setLiquidationModule(address(liquidation));
        vm.stopPrank();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = PoolId.unwrap(poolKey.toId());

        token0.mint(user, 1_000_000 ether);
        token1.mint(user, 1_000_000 ether);
        token1.mint(supplier, 2_000_000 ether);
        token1.mint(liquidator, 2_000_000 ether);
        token1.mint(address(flashProvider), 2_000_000 ether);

        vm.prank(supplier);
        token1.approve(address(market), type(uint256).max);
        vm.prank(supplier);
        market.supply(1_000_000 ether, supplier);

        vm.prank(user);
        token0.approve(address(router), type(uint256).max);
        vm.prank(user);
        token1.approve(address(router), type(uint256).max);
        vm.prank(user);
        token1.approve(address(market), type(uint256).max);

        vm.prank(liquidator);
        token1.approve(address(market), type(uint256).max);

        metricsHook.setPoolMetrics(poolId, 0, 30, 200_000);

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
        vm.prank(admin);
        riskManager.setPoolRiskConfig(poolId, cfg);
    }
}
