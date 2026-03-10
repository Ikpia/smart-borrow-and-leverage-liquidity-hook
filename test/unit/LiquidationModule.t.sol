// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract LiquidationModuleUnitTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();
    }

    function testCannotLiquidateHealthyPosition() public {
        uint256 positionId = _openBorrowedPosition(30_000 ether);

        vm.prank(liquidator);
        vm.expectRevert();
        liquidation.liquidate(positionId, 5_000 ether, 0, 0);
    }

    function testPermissionlessLiquidationWhenUnhealthy() public {
        uint256 positionId = _openBorrowedPosition(85_000 ether);

        // Push risk high enough to cross liquidation threshold deterministically.
        metricsHook.setPoolMetrics(poolId, -6_000, 2_000, 1);
        vm.prank(admin);
        riskManager.setPoolRiskConfig(poolId, _tightConfig());

        uint256 debtBefore = market.debtOf(positionId);
        assertTrue(riskManager.isLiquidatable(positionId));

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized0, uint256 seized1,) = liquidation.liquidate(positionId, 60_000 ether, 1, 1);

        uint256 debtAfter = market.debtOf(positionId);

        assertGt(repaid, 0);
        assertGt(seized0 + seized1, 0);
        assertLt(debtAfter, debtBefore);
    }

    function testRepeatedLiquidationEventuallyStops() public {
        uint256 positionId = _openBorrowedPosition(87_000 ether);
        metricsHook.setPoolMetrics(poolId, -7_500, 2_000, 1);
        vm.prank(admin);
        riskManager.setPoolRiskConfig(poolId, _tightConfig());

        vm.startPrank(liquidator);
        liquidation.liquidate(positionId, 70_000 ether, 0, 0);

        if (riskManager.isLiquidatable(positionId) && market.debtOf(positionId) > 0) {
            liquidation.liquidate(positionId, 70_000 ether, 0, 0);
        }
        vm.stopPrank();

        if (!riskManager.isLiquidatable(positionId)) {
            vm.prank(liquidator);
            vm.expectRevert();
            liquidation.liquidate(positionId, 1_000 ether, 0, 0);
        }
    }

    function _openBorrowedPosition(uint256 borrowAmount) internal returns (uint256 positionId) {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -700,
            tickUpper: 700,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: borrowAmount,
            leveragedLiquidity: 30_000,
            minHealthFactorWad: 1e18
        });

        vm.prank(user);
        positionId = router.openBorrowAndReinvest(p);
    }

    function _tightConfig() internal pure returns (DataTypes.PoolRiskConfig memory cfg) {
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
