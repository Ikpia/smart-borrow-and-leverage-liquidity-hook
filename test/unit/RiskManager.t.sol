// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract RiskManagerUnitTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();
    }

    function testDynamicLtvDropsWithVolatilityAndDistance() public {
        uint256 positionId = _openBasePosition();

        DataTypes.RiskSnapshot memory calm = riskManager.snapshot(positionId);

        metricsHook.setPoolMetrics(poolId, 1_000, 900, 20_000);
        DataTypes.RiskSnapshot memory stressed = riskManager.snapshot(positionId);

        assertLt(stressed.adjustedLtvBps, calm.adjustedLtvBps);
        assertLt(stressed.collateralValueQuote, calm.collateralValueQuote);
        assertLt(stressed.maxBorrowQuote, calm.maxBorrowQuote);
    }

    function testCanBorrowBoundaryAtMaxLtv() public {
        uint256 positionId = _openBasePosition();
        DataTypes.RiskSnapshot memory s = riskManager.snapshot(positionId);

        bool okAtBoundary = riskManager.canBorrow(positionId, s.maxBorrowQuote);
        bool tooHigh = riskManager.canBorrow(positionId, s.maxBorrowQuote + 1);

        assertTrue(okAtBoundary);
        assertFalse(tooHigh);
    }

    function testHealthFactorFallsAfterBorrow() public {
        uint256 positionId = _openBasePosition();
        uint256 hfBefore = riskManager.healthFactorWad(positionId);

        vm.prank(user);
        router.borrowAndReinvest(positionId, 40_000 ether, 10_000, 1e18);

        uint256 hfAfter = riskManager.healthFactorWad(positionId);
        assertLt(hfAfter, hfBefore);
        assertGe(hfAfter, 1e18);
    }

    function _openBasePosition() internal returns (uint256 positionId) {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -600,
            tickUpper: 600,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: 0,
            leveragedLiquidity: 0,
            minHealthFactorWad: 1e18
        });

        vm.prank(user);
        positionId = router.openBorrowAndReinvest(p);
    }
}
