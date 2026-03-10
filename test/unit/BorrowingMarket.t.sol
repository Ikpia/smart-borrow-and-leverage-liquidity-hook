// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";

contract BorrowingMarketUnitTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();

        vm.prank(admin);
        market.setBorrower(address(this), true);
        vm.prank(admin);
        market.setRepayer(address(this), true);
    }

    function testSupplyAndWithdrawRoundTrip() public {
        uint256 beforeBal = token1.balanceOf(supplier);

        vm.startPrank(supplier);
        uint256 shares = market.supply(10_000 ether, supplier);
        uint256 out = market.withdraw(shares, supplier);
        vm.stopPrank();

        assertGt(shares, 0);
        assertApproxEqAbs(out, 10_000 ether, 2);
        assertApproxEqAbs(token1.balanceOf(supplier), beforeBal, 2);
    }

    function testInterestAccruesMonotonically() public {
        borrowFor(1, address(this), 100_000 ether);

        uint256 debt0 = market.debtOf(1);

        vm.warp(block.timestamp + 7 days);
        market.accrueInterest();
        uint256 debt1 = market.debtOf(1);

        vm.warp(block.timestamp + 14 days);
        market.accrueInterest();
        uint256 debt2 = market.debtOf(1);

        assertGt(debt1, debt0);
        assertGt(debt2, debt1);
    }

    function testRepayOverPaysOnlyOutstandingDebt() public {
        borrowFor(2, address(this), 50_000 ether);
        vm.warp(block.timestamp + 3 days);

        uint256 debt = market.debtOf(2);
        token1.mint(address(this), debt * 2);
        token1.approve(address(market), type(uint256).max);

        uint256 repaid = market.repayFor(2, address(this), debt * 2);

        assertEq(repaid, debt);
        assertEq(market.debtOf(2), 0);
    }

    function borrowFor(uint256 positionId, address receiver, uint256 amount) internal {
        market.borrowFor(positionId, receiver, amount);
    }
}
