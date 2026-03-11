// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";

import {BorrowingMarket} from "../../src/markets/BorrowingMarket.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract BorrowingMarketEdgeTest is ProtocolFixture {
    using stdStorage for StdStorage;

    StdStorage private _stdstore;

    function setUp() public {
        setUpFixture();
    }

    function testAccessControlReverts() public {
        vm.prank(user);
        vm.expectRevert(BorrowingMarket.NotBorrower.selector);
        market.borrowFor(1, user, 1 ether);

        vm.prank(user);
        vm.expectRevert(BorrowingMarket.NotRepayer.selector);
        market.repayFor(1, user, 1 ether);

        vm.prank(user);
        vm.expectRevert(BorrowingMarket.NotLiquidationModule.selector);
        market.forgiveBadDebt(1);
    }

    function testSetRateConfigValidationAndUpdate() public {
        BorrowingMarket.RateConfig memory invalidKink = BorrowingMarket.RateConfig({
            kinkUtilizationBps: 0,
            reserveFactorBps: 1_000,
            baseRatePerYearRay: 0.04e27,
            slope1PerYearRay: 0.16e27,
            slope2PerYearRay: 1.8e27
        });

        vm.prank(admin);
        vm.expectRevert(BorrowingMarket.InvalidConfig.selector);
        market.setRateConfig(invalidKink);

        BorrowingMarket.RateConfig memory invalidReserve = BorrowingMarket.RateConfig({
            kinkUtilizationBps: 8_000,
            reserveFactorBps: 10_001,
            baseRatePerYearRay: 0.04e27,
            slope1PerYearRay: 0.16e27,
            slope2PerYearRay: 1.8e27
        });

        vm.prank(admin);
        vm.expectRevert(BorrowingMarket.InvalidConfig.selector);
        market.setRateConfig(invalidReserve);

        BorrowingMarket.RateConfig memory valid = BorrowingMarket.RateConfig({
            kinkUtilizationBps: 7_000,
            reserveFactorBps: 1_500,
            baseRatePerYearRay: 0.03e27,
            slope1PerYearRay: 0.25e27,
            slope2PerYearRay: 2e27
        });

        vm.prank(admin);
        market.setRateConfig(valid);

        (
            uint16 kinkUtilizationBps,
            uint16 reserveFactorBps,
            uint256 baseRatePerYearRay,
            uint256 slope1PerYearRay,
            uint256 slope2PerYearRay
        ) = market.rateConfig();

        assertEq(kinkUtilizationBps, valid.kinkUtilizationBps);
        assertEq(reserveFactorBps, valid.reserveFactorBps);
        assertEq(baseRatePerYearRay, valid.baseRatePerYearRay);
        assertEq(slope1PerYearRay, valid.slope1PerYearRay);
        assertEq(slope2PerYearRay, valid.slope2PerYearRay);
    }

    function testSupplyOnBehalfAndZeroSupplyReverts() public {
        vm.startPrank(supplier);
        vm.expectRevert(BorrowingMarket.InvalidConfig.selector);
        market.supply(0, address(0));

        uint256 shares = market.supply(10_000 ether, address(0));
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(market.supplyShares(supplier), 1_010_000 ether);
    }

    function testWithdrawValidationAndInsufficientLiquidity() public {
        vm.prank(supplier);
        vm.expectRevert(BorrowingMarket.InvalidConfig.selector);
        market.withdraw(0, supplier);

        vm.prank(supplier);
        vm.expectRevert(BorrowingMarket.InvalidConfig.selector);
        market.withdraw(type(uint256).max, supplier);

        vm.prank(admin);
        market.setBorrower(address(this), true);
        market.borrowFor(99, address(this), 999_000 ether);

        uint256 shares = market.supplyShares(supplier);
        vm.prank(supplier);
        vm.expectRevert(BorrowingMarket.InsufficientLiquidity.selector);
        market.withdraw(shares, supplier);
    }

    function testBorrowAndRepayEdgeBranches() public {
        vm.prank(admin);
        market.setBorrower(address(this), true);
        vm.prank(admin);
        market.setRepayer(address(this), true);

        vm.expectRevert(BorrowingMarket.InsufficientLiquidity.selector);
        market.borrowFor(1, address(this), 2_000_000 ether);

        assertEq(market.repayFor(7, address(this), 100 ether), 0);

        market.borrowFor(7, address(this), 100_000 ether);

        vm.warp(block.timestamp + 7 days);
        market.accrueInterest();

        uint256 debtBefore = market.debtOf(7);

        token1.mint(address(this), 1_000_000 ether);
        token1.approve(address(market), type(uint256).max);

        // Tiny partial repay executes the scaledReduction==0 => 1 guard branch.
        uint256 repaidTiny = market.repayFor(7, address(this), 1);
        assertEq(repaidTiny, 1);

        uint256 debtAfterTiny = market.debtOf(7);
        assertLt(debtAfterTiny, debtBefore);

        uint256 repaidZeroAmount = market.repayFor(7, address(this), 0);
        assertEq(repaidZeroAmount, 0);

        uint256 repaidRest = market.repayFor(7, address(this), type(uint256).max);
        assertEq(market.debtOf(7), 0);
        assertGt(repaidRest, 0);
    }

    function testAccrualPreviewAndUtilizationPaths() public {
        uint256 idx0 = market.previewBorrowIndexRay();
        market.accrueInterest(); // dt == 0 path
        assertEq(market.previewBorrowIndexRay(), idx0);

        vm.warp(block.timestamp + 1 days);
        market.accrueInterest(); // totalScaledDebt == 0 path
        uint256 idx1 = market.previewBorrowIndexRay();
        assertEq(idx1, idx0);

        vm.prank(admin);
        market.setBorrower(address(this), true);
        market.borrowFor(3, address(this), 980_000 ether); // post-kink utilization branch

        vm.warp(block.timestamp + 2 days);
        market.accrueInterest();

        assertGt(market.totalDebt(), 980_000 ether);
        assertGt(market.previewBorrowRatePerYearRay(), 0);
        assertGt(market.utilizationBps(), 8_000);
        assertGt(market.totalAssets(), 0);
    }

    function testBorrowZeroAmountAndTotalAssetsLossClamp() public {
        vm.prank(admin);
        market.setBorrower(address(this), true);

        // Exercises _toScaledUp amount==0 branch.
        market.borrowFor(31337, address(this), 0);
        assertEq(market.debtOf(31337), 0);

        _stdstore.target(address(market)).sig("reserveBalance()").checked_write(uint256(1e40));
        _stdstore.target(address(market)).sig("badDebt()").checked_write(uint256(1e40));
        assertEq(market.totalAssets(), 0);
    }

    function testForgiveBadDebtBranches() public {
        vm.prank(admin);
        market.setBorrower(address(this), true);
        vm.prank(admin);
        market.setLiquidationModule(address(this));

        // zero-debt early return
        assertEq(market.forgiveBadDebt(404), 0);

        market.borrowFor(11, address(this), 10_000 ether);
        uint256 writtenOff = market.debtOf(11);

        // reserve >= writtenOff branch
        _stdstore.target(address(market)).sig("reserveBalance()").checked_write(uint256(writtenOff + 1 ether));
        uint256 badDebtBefore = market.badDebt();
        uint256 reserveBefore = market.reserveBalance();

        uint256 forgiven = market.forgiveBadDebt(11);
        assertEq(forgiven, writtenOff);
        assertEq(market.badDebt(), badDebtBefore);
        assertEq(market.reserveBalance(), reserveBefore - writtenOff);

        // reserve < writtenOff branch
        market.borrowFor(12, address(this), 20_000 ether);
        _stdstore.target(address(market)).sig("reserveBalance()").checked_write(uint256(0));
        uint256 debt2 = market.debtOf(12);
        uint256 badDebtBefore2 = market.badDebt();

        uint256 forgiven2 = market.forgiveBadDebt(12);
        assertEq(forgiven2, debt2);
        assertEq(market.badDebt(), badDebtBefore2 + debt2);
        assertEq(market.reserveBalance(), 0);
    }
}
