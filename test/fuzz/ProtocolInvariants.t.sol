// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract ProtocolHandler is ProtocolFixture {
    uint256 public trackedPositionId;

    function setUp() public {
        setUpFixture();
    }

    function openIfNeeded() external {
        if (trackedPositionId != 0) return;

        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -1_000,
            tickUpper: 1_000,
            baseLiquidity: 100_000,
            collateral0: 120_000 ether,
            collateral1: 120_000 ether,
            borrowAmount: 0,
            leveragedLiquidity: 0,
            minHealthFactorWad: 1e18
        });

        vm.prank(user);
        trackedPositionId = router.openBorrowAndReinvest(p);
    }

    function borrowBounded(uint96 amount) external {
        if (trackedPositionId == 0) return;

        DataTypes.RiskSnapshot memory s = riskManager.snapshot(trackedPositionId);
        if (s.maxBorrowQuote <= s.debtQuote) return;

        uint256 room = s.maxBorrowQuote - s.debtQuote;
        uint256 borrowAmt = bound(uint256(amount), 1, room);

        vm.prank(user);
        router.borrowAndReinvest(trackedPositionId, borrowAmt, uint128(borrowAmt / 10), 1e18);
    }

    function repayBounded(uint96 amount) external {
        if (trackedPositionId == 0) return;

        uint256 debt = market.debtOf(trackedPositionId);
        if (debt == 0) return;

        uint256 repayAmt = bound(uint256(amount), 1, debt);

        vm.prank(user);
        router.repayAndUnwind(trackedPositionId, repayAmt, 0, 0, 0);
    }

    function updateVolatility(uint24 vol, int24 tick) external {
        int256 tickInt = int256(tick);
        uint256 absTick = uint256(tickInt >= 0 ? tickInt : -tickInt);
        int24 boundedTick = int24(int256(bound(absTick, 0, 100_000)));
        if (tickInt < 0) boundedTick = -boundedTick;
        metricsHook.setPoolMetrics(poolId, boundedTick, vol, 100_000);
    }

    function advanceTime(uint32 dt) external {
        vm.warp(block.timestamp + bound(uint256(dt), 1, 7 days));
        market.accrueInterest();
    }
}

contract ProtocolInvariantsTest is StdInvariant, Test {
    ProtocolHandler internal handler;

    function setUp() public {
        handler = new ProtocolHandler();
        handler.setUp();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.openIfNeeded.selector;
        selectors[1] = handler.borrowBounded.selector;
        selectors[2] = handler.repayBounded.selector;
        selectors[3] = handler.updateVolatility.selector;
        selectors[4] = handler.advanceTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        excludeContract(address(handler.vault()));
        excludeContract(address(handler.market()));
        excludeContract(address(handler.riskManager()));
        excludeContract(address(handler.router()));
        excludeContract(address(handler.liquidation()));
        excludeContract(address(handler.flashModule()));
        excludeContract(address(handler.flashProvider()));
        excludeContract(address(handler.token0()));
        excludeContract(address(handler.token1()));
        excludeContract(address(handler.metricsHook()));
    }

    function invariant_HealthyStateMatchesLiquidationPredicate() public view {
        uint256 id = handler.trackedPositionId();
        if (id == 0) return;

        bool healthy = handler.riskManager().isHealthy(id);
        bool liquidatable = handler.riskManager().isLiquidatable(id);
        assertEq(healthy, !liquidatable);
    }

    function invariant_DebtAccountingConsistent() public view {
        uint256 id = handler.trackedPositionId();
        if (id == 0) return;

        uint256 debt = handler.market().debtOf(id);
        DataTypes.RiskSnapshot memory s = handler.riskManager().snapshot(id);

        assertEq(debt, s.debtQuote);
        assertTrue(s.healthFactorWad > 0);
    }
}
