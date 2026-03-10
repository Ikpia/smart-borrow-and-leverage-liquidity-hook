// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract ProtocolFuzzTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();
    }

    function testFuzzCannotBorrowBeyondMaxLtv(uint96 extraBorrow) public {
        uint256 positionId = _openBasePosition();
        DataTypes.RiskSnapshot memory s = riskManager.snapshot(positionId);

        uint256 extra = bound(uint256(extraBorrow), 1, 2_000_000 ether);
        uint256 request = s.maxBorrowQuote + extra;

        vm.prank(user);
        vm.expectRevert();
        router.borrowAndReinvest(positionId, request, uint128(bound(extra, 1, 100_000)), 1e18);
    }

    function testFuzzDebtAccrualMonotonic(uint64 dt1, uint64 dt2) public {
        uint256 positionId = _openBorrowedPosition(25_000 ether);

        uint256 d0 = market.debtOf(positionId);

        vm.warp(block.timestamp + bound(dt1, 1, 30 days));
        market.accrueInterest();
        uint256 d1 = market.debtOf(positionId);

        vm.warp(block.timestamp + bound(dt2, 1, 30 days));
        market.accrueInterest();
        uint256 d2 = market.debtOf(positionId);

        assertGe(d1, d0);
        assertGe(d2, d1);
    }

    function testFuzzLiquidationCannotRunWhenHealthy(uint96 repayAttempt) public {
        uint256 positionId = _openBorrowedPosition(10_000 ether);
        vm.assume(!riskManager.isLiquidatable(positionId));

        uint256 repay = bound(uint256(repayAttempt), 1, 100_000 ether);

        vm.prank(liquidator);
        vm.expectRevert();
        liquidation.liquidate(positionId, repay, 0, 0);
    }

    function testFuzzFlashLeverageLeavesNoFlashDebt(uint96 amountIn, uint24 tickDistance) public {
        uint256 positionId = _openBasePosition();

        uint256 flashAmount = bound(uint256(amountIn), 1 ether, 50_000 ether);
        uint24 maxDistance = uint24(bound(uint256(tickDistance), 200, 3_000));

        vm.prank(user);
        flashModule.flashLeverage(positionId, flashAmount, uint128(flashAmount / 10), 1e18, maxDistance);

        assertEq(token1.balanceOf(address(flashProvider)), 2_000_000 ether + ((flashAmount * flashProvider.feeBps()) / 10_000));
    }

    function _openBasePosition() internal returns (uint256 positionId) {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -1_000,
            tickUpper: 1_000,
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

    function _openBorrowedPosition(uint256 borrowAmount) internal returns (uint256 positionId) {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -1_000,
            tickUpper: 1_000,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: borrowAmount,
            leveragedLiquidity: 10_000,
            minHealthFactorWad: 1e18
        });

        vm.prank(user);
        positionId = router.openBorrowAndReinvest(p);
    }
}
