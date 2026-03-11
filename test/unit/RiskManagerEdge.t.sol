// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";

import {MockToken} from "../../src/mocks/MockToken.sol";
import {BorrowingMarket} from "../../src/markets/BorrowingMarket.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {IBorrowingMarket} from "../../src/interfaces/IBorrowingMarket.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {ILeverageLiquidityHook} from "../../src/interfaces/ILeverageLiquidityHook.sol";

contract RiskManagerHarness is RiskManager {
    constructor(address admin, ILPVault vault_, IBorrowingMarket market_, ILeverageLiquidityHook hook_)
        RiskManager(admin, vault_, market_, hook_)
    {}

    function exposedAdjustedLiquidationLtv(DataTypes.PoolRiskConfig memory cfg, uint16 penalty, uint16 adjustedLtv)
        external
        pure
        returns (uint16)
    {
        return _adjustedLiquidationLtv(cfg, penalty, adjustedLtv);
    }

    function exposedApplyPenaltyFloor(uint16 baseValue, uint16 floorValue, uint16 penalty) external pure returns (uint16) {
        return _applyPenaltyFloor(baseValue, floorValue, penalty);
    }

    function exposedLinearPenalty(uint24 value, uint24 maxValue, uint16 maxPenalty) external pure returns (uint16) {
        return _linearPenalty(value, maxValue, maxPenalty);
    }

    function exposedRangeWidth(int24 tickLower, int24 tickUpper) external pure returns (uint24) {
        return _rangeWidth(tickLower, tickUpper);
    }

    function exposedAbsTickDiff(int24 a, int24 b) external pure returns (uint24) {
        return _absTickDiff(a, b);
    }
}

contract RiskManagerEdgeTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();

        vm.prank(admin);
        vault.setOperator(address(this), true);
    }

    function testSnapshotInactiveAndMaxBorrowableZeroPath() public {
        DataTypes.RiskSnapshot memory empty = riskManager.snapshot(404);
        assertEq(empty.maxBorrowQuote, 0);
        assertEq(empty.healthFactorWad, 0);

        // Use an unconfigured poolId to exercise default config fallback.
        bytes32 unconfiguredPoolId = keccak256("unconfigured-pool");
        uint256 fallbackId = _openPosition(unconfiguredPoolId, address(token0), address(token1), 20_000 ether, 20_000 ether);
        DataTypes.RiskSnapshot memory fallbackSnap = riskManager.snapshot(fallbackId);
        assertGt(fallbackSnap.adjustedLtvBps, 0);

        uint256 id = _openPosition(poolId, address(token0), address(token1), 50_000 ether, 50_000 ether);
        DataTypes.RiskSnapshot memory s = riskManager.snapshot(id);
        assertGt(s.maxBorrowQuote, 0);
        assertEq(riskManager.maxBorrowable(id), s.maxBorrowQuote);

        vm.prank(admin);
        market.setBorrower(address(this), true);
        market.borrowFor(id, address(this), s.maxBorrowQuote + 1);

        assertEq(riskManager.maxBorrowable(id), 0);
    }

    function testDefaultConfigSettersAndValidationReverts() public {
        DataTypes.PoolRiskConfig memory cfg = _validCfg();
        cfg.stablePool = true;

        vm.prank(admin);
        riskManager.setDefaultStableConfig(cfg);
        vm.prank(admin);
        riskManager.setDefaultVolatileConfig(_validCfg());

        DataTypes.PoolRiskConfig memory invalid = _validCfg();
        invalid.enabled = false;
        vm.prank(admin);
        vm.expectRevert(RiskManager.InvalidPoolConfig.selector);
        riskManager.setDefaultVolatileConfig(invalid);

        invalid = _validCfg();
        invalid.baseLtvBps = 0;
        vm.prank(admin);
        vm.expectRevert(RiskManager.InvalidPoolConfig.selector);
        riskManager.setPoolRiskConfig(poolId, invalid);

        invalid = _validCfg();
        invalid.liquidationLtvBps = invalid.baseLtvBps;
        vm.prank(admin);
        vm.expectRevert(RiskManager.InvalidPoolConfig.selector);
        riskManager.setPoolRiskConfig(poolId, invalid);

        invalid = _validCfg();
        invalid.minLtvBps = invalid.baseLtvBps + 1;
        vm.prank(admin);
        vm.expectRevert(RiskManager.InvalidPoolConfig.selector);
        riskManager.setPoolRiskConfig(poolId, invalid);

        invalid = _validCfg();
        invalid.baseCollateralFactorBps = 9_000;
        invalid.minCollateralFactorBps = 9_500;
        vm.prank(admin);
        vm.expectRevert(RiskManager.InvalidPoolConfig.selector);
        riskManager.setPoolRiskConfig(poolId, invalid);

        invalid = _validCfg();
        invalid.maxVolatilityPenaltyBps = invalid.baseLtvBps;
        invalid.maxDepthPenaltyBps = 1;
        vm.prank(admin);
        vm.expectRevert(RiskManager.InvalidPoolConfig.selector);
        riskManager.setPoolRiskConfig(poolId, invalid);
    }

    function testBorrowAssetToken0AndUnsupportedBorrowAsset() public {
        vm.prank(admin);
        BorrowingMarket market0 = new BorrowingMarket(address(token0), admin);
        vm.prank(admin);
        RiskManager risk0 = new RiskManager(admin, vault, market0, metricsHook);
        vm.prank(admin);
        risk0.setPoolRiskConfig(poolId, _validCfg());

        uint256 id = _openPosition(poolId, address(token0), address(token1), 10_000 ether, 20_000 ether);
        DataTypes.RiskSnapshot memory s0 = risk0.snapshot(id);
        assertGt(s0.rawValueQuote, 10_000 ether);

        MockToken token2 = new MockToken("Unsupported", "UNSUP", 18);
        vm.prank(admin);
        BorrowingMarket marketX = new BorrowingMarket(address(token2), admin);
        vm.prank(admin);
        RiskManager riskX = new RiskManager(admin, vault, marketX, metricsHook);
        vm.prank(admin);
        riskX.setPoolRiskConfig(poolId, _validCfg());

        vm.expectRevert(RiskManager.UnsupportedBorrowAsset.selector);
        riskX.snapshot(id);
    }

    function testHelperFunctionsViaHarness() public {
        vm.prank(admin);
        RiskManagerHarness harness = new RiskManagerHarness(admin, vault, market, metricsHook);

        DataTypes.PoolRiskConfig memory cfg = _validCfg();
        uint16 liq = harness.exposedAdjustedLiquidationLtv(cfg, 9_999, 9_999);
        assertEq(liq, DataTypes.BPS);

        // Force the >BPS clamp branch in _adjustedLiquidationLtv via harness inputs.
        uint16 liqClamped = harness.exposedAdjustedLiquidationLtv(cfg, 0, DataTypes.BPS);
        assertEq(liqClamped, DataTypes.BPS);

        assertEq(harness.exposedApplyPenaltyFloor(5_000, 4_000, 2_000), 4_000);
        assertEq(harness.exposedApplyPenaltyFloor(8_000, 5_000, 100), 7_900);

        assertEq(harness.exposedLinearPenalty(0, 100, 900), 0);
        assertEq(harness.exposedLinearPenalty(100, 100, 900), 900);
        assertEq(harness.exposedLinearPenalty(50, 100, 900), 450);

        assertEq(harness.exposedRangeWidth(10, 5), 0);
        assertEq(harness.exposedRangeWidth(-100, 100), 200);

        assertEq(harness.exposedAbsTickDiff(500, -500), 1_000);
        assertEq(harness.exposedAbsTickDiff(-1, -1), 0);
    }

    function _openPosition(bytes32 idPool, address t0, address t1, uint256 c0, uint256 c1) internal returns (uint256 id) {
        id = vault.openPosition(user, idPool, t0, t1, -600, 600, 0, c0, c1);
    }

    function _validCfg() internal pure returns (DataTypes.PoolRiskConfig memory cfg) {
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
