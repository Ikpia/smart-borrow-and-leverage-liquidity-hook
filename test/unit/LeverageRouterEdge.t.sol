// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";

import {MockToken} from "../../src/mocks/MockToken.sol";
import {BorrowingMarket} from "../../src/markets/BorrowingMarket.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract MockRouterRisk {
    bool public allowBorrow = true;
    uint256 public hf = 2e18;

    function setBorrowAllowed(bool allowed) external {
        allowBorrow = allowed;
    }

    function setHealth(uint256 newHealth) external {
        hf = newHealth;
    }

    function canBorrow(uint256, uint256) external view returns (bool) {
        return allowBorrow;
    }

    function healthFactorWad(uint256) external view returns (uint256) {
        return hf;
    }
}

contract LeverageRouterEdgeTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();
    }

    function testBorrowAndReinvestNotOwnerReverts() public {
        uint256 positionId = _openPositionNoBorrow();

        vm.prank(liquidator);
        vm.expectRevert(LeverageRouter.NotPositionOwner.selector);
        router.borrowAndReinvest(positionId, 1_000 ether, 100, 1e18);
    }

    function testRepayAndUnwindNotOwnerReverts() public {
        uint256 positionId = _openPositionNoBorrow();

        vm.prank(liquidator);
        vm.expectRevert(LeverageRouter.NotPositionOwner.selector);
        router.repayAndUnwind(positionId, 0, 0, 0, 0);
    }

    function testRepayAllAndWithdrawNotOwnerReverts() public {
        uint256 positionId = _openPositionNoBorrow();

        vm.prank(liquidator);
        vm.expectRevert(LeverageRouter.NotPositionOwner.selector);
        router.repayAllAndWithdraw(positionId);
    }

    function testBorrowAndReinvestHealthFactorGuard() public {
        uint256 positionId = _openPositionNoBorrow();

        vm.prank(user);
        vm.expectRevert();
        router.borrowAndReinvest(positionId, 10_000 ether, 1_000, type(uint256).max);
    }

    function testRepayAndUnwindRevertsIfStillUnhealthy() public {
        uint256 positionId = _openBorrowedPosition(80_000 ether);

        metricsHook.setPoolMetrics(poolId, -8_000, 2_000, 1);
        vm.prank(admin);
        riskManager.setPoolRiskConfig(poolId, _tightCfg());
        assertTrue(riskManager.isLiquidatable(positionId));

        vm.prank(user);
        vm.expectRevert();
        router.repayAndUnwind(positionId, 0, 0, 0, 0);
    }

    function testRepayAllAndWithdrawFlow() public {
        uint256 positionId = _openBorrowedPosition(25_000 ether);
        uint256 debtBefore = market.debtOf(positionId);
        assertGt(debtBefore, 0);

        vm.prank(user);
        router.repayAllAndWithdraw(positionId);

        DataTypes.Position memory p = vault.position(positionId);
        assertEq(market.debtOf(positionId), 0);
        assertEq(p.collateral0, 0);
        assertEq(p.collateral1, 0);
        assertEq(p.leveragedLiquidity, 0);
    }

    function testRepayAllAndWithdrawWhenDebtIsZero() public {
        uint256 positionId = _openPositionNoBorrow();

        vm.prank(user);
        router.repayAllAndWithdraw(positionId);

        DataTypes.Position memory p = vault.position(positionId);
        assertEq(market.debtOf(positionId), 0);
        assertEq(p.collateral0, 0);
        assertEq(p.collateral1, 0);
    }

    function testOpenPositionWithSingleSidedCollateral() public {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -1_000,
            tickUpper: 1_000,
            baseLiquidity: 100_000,
            collateral0: 10_000 ether,
            collateral1: 0,
            borrowAmount: 0,
            leveragedLiquidity: 0,
            minHealthFactorWad: 1e18
        });

        uint256 bal0Before = token0.balanceOf(user);
        uint256 bal1Before = token1.balanceOf(user);

        vm.prank(user);
        uint256 positionId = router.openBorrowAndReinvest(p);

        DataTypes.Position memory pos = vault.position(positionId);
        assertEq(pos.collateral0, 10_000 ether);
        assertEq(pos.collateral1, 0);
        assertEq(token0.balanceOf(user), bal0Before - 10_000 ether);
        assertEq(token1.balanceOf(user), bal1Before);
    }

    function testOpenPositionWithOnlyCollateral1() public {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -1_000,
            tickUpper: 1_000,
            baseLiquidity: 100_000,
            collateral0: 0,
            collateral1: 9_000 ether,
            borrowAmount: 0,
            leveragedLiquidity: 0,
            minHealthFactorWad: 1e18
        });

        uint256 bal0Before = token0.balanceOf(user);
        uint256 bal1Before = token1.balanceOf(user);

        vm.prank(user);
        uint256 positionId = router.openBorrowAndReinvest(p);

        DataTypes.Position memory pos = vault.position(positionId);
        assertEq(pos.collateral0, 0);
        assertEq(pos.collateral1, 9_000 ether);
        assertEq(token0.balanceOf(user), bal0Before);
        assertEq(token1.balanceOf(user), bal1Before - 9_000 ether);
    }

    function testInvalidBorrowAssetBranch() public {
        MockToken token2 = new MockToken("BorrowX", "BRWX", 18);
        vm.prank(admin);
        BorrowingMarket marketX = new BorrowingMarket(address(token2), admin);

        MockRouterRisk mockRisk = new MockRouterRisk();
        LeverageRouter routerX = new LeverageRouter(vault, marketX, RiskManager(address(mockRisk)));

        vm.startPrank(admin);
        vault.setOperator(address(routerX), true);
        marketX.setBorrower(address(routerX), true);
        marketX.setRepayer(address(routerX), true);
        vm.stopPrank();

        token2.mint(supplier, 500_000 ether);
        vm.prank(supplier);
        token2.approve(address(marketX), type(uint256).max);
        vm.prank(supplier);
        marketX.supply(500_000 ether, supplier);

        vm.prank(user);
        token0.approve(address(routerX), type(uint256).max);
        vm.prank(user);
        token1.approve(address(routerX), type(uint256).max);

        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -1_000,
            tickUpper: 1_000,
            baseLiquidity: 10_000,
            collateral0: 1_000 ether,
            collateral1: 1_000 ether,
            borrowAmount: 0,
            leveragedLiquidity: 0,
            minHealthFactorWad: 1e18
        });

        vm.prank(user);
        uint256 positionId = routerX.openBorrowAndReinvest(p);

        vm.prank(user);
        vm.expectRevert(LeverageRouter.InvalidBorrowAsset.selector);
        routerX.borrowAndReinvest(positionId, 100 ether, 10, 1e18);
    }

    function testBorrowPathWhenBorrowAssetIsToken0() public {
        vm.prank(admin);
        BorrowingMarket market0 = new BorrowingMarket(address(token0), admin);
        vm.prank(admin);
        RiskManager risk0 = new RiskManager(admin, vault, market0, metricsHook);
        LeverageRouter router0 = new LeverageRouter(vault, market0, risk0);

        vm.startPrank(admin);
        vault.setOperator(address(router0), true);
        market0.setBorrower(address(router0), true);
        market0.setRepayer(address(router0), true);
        risk0.setPoolRiskConfig(poolId, _normalCfg());
        vm.stopPrank();

        token0.mint(supplier, 500_000 ether);
        vm.prank(supplier);
        token0.approve(address(market0), type(uint256).max);
        vm.prank(supplier);
        market0.supply(500_000 ether, supplier);

        vm.prank(user);
        token0.approve(address(router0), type(uint256).max);
        vm.prank(user);
        token1.approve(address(router0), type(uint256).max);

        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -1_000,
            tickUpper: 1_000,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: 40_000 ether,
            leveragedLiquidity: 10_000,
            minHealthFactorWad: 1e18
        });

        vm.prank(user);
        uint256 positionId = router0.openBorrowAndReinvest(p);

        DataTypes.Position memory pos = vault.position(positionId);
        assertEq(pos.collateral0, 140_000 ether);
        assertEq(pos.collateral1, 100_000 ether);
        assertEq(market0.debtOf(positionId), 40_000 ether);
    }

    function _openPositionNoBorrow() internal returns (uint256 positionId) {
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
            tickLower: -700,
            tickUpper: 700,
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

    function _tightCfg() internal pure returns (DataTypes.PoolRiskConfig memory cfg) {
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

    function _normalCfg() internal pure returns (DataTypes.PoolRiskConfig memory cfg) {
        cfg = DataTypes.PoolRiskConfig({
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
    }
}
