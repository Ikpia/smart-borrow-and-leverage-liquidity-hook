// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";

import {RiskManager} from "../../src/RiskManager.sol";
import {LiquidationModule} from "../../src/modules/LiquidationModule.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract MockLiquidationRisk {
    bool public liquidatable = true;
    bool public healthy = false;

    function setState(bool isLiquidatable_, bool isHealthy_) external {
        liquidatable = isLiquidatable_;
        healthy = isHealthy_;
    }

    function isLiquidatable(uint256) external view returns (bool) {
        return liquidatable;
    }

    function isHealthy(uint256) external view returns (bool) {
        return healthy;
    }
}

contract LiquidationModuleEdgeTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();
        token0.mint(address(vault), 1_000_000 ether);
        token1.mint(address(vault), 1_000_000 ether);
    }

    function testSetLiquidationParamsValidation() public {
        vm.prank(admin);
        vm.expectRevert(LiquidationModule.InvalidRepayAmount.selector);
        liquidation.setLiquidationParams(0, 0);

        vm.prank(admin);
        vm.expectRevert(LiquidationModule.InvalidRepayAmount.selector);
        liquidation.setLiquidationParams(DataTypes.BPS + 1, 0);

        vm.prank(admin);
        vm.expectRevert(LiquidationModule.InvalidRepayAmount.selector);
        liquidation.setLiquidationParams(5_000, DataTypes.BPS + 1);

        vm.prank(admin);
        liquidation.setLiquidationParams(6_000, 900);
        assertEq(liquidation.closeFactorBps(), 6_000);
        assertEq(liquidation.liquidationBonusBps(), 900);
    }

    function testDebtZeroAndMaxRepayFallbackBranches() public {
        MockLiquidationRisk mockRisk = new MockLiquidationRisk();
        vm.prank(admin);
        LiquidationModule module = new LiquidationModule(admin, vault, market, RiskManager(address(mockRisk)));

        vm.startPrank(admin);
        vault.setLiquidationModule(address(module));
        market.setRepayer(address(module), true);
        market.setLiquidationModule(address(module));
        market.setBorrower(address(this), true);
        vm.stopPrank();

        vm.prank(admin);
        vault.setOperator(address(this), true);

        // Debt == 0 branch after passing liquidatable check
        uint256 emptyId =
            vault.openPosition(user, poolId, address(token0), address(token1), -300, 300, 0, 100 ether, 100 ether);
        vm.prank(liquidator);
        vm.expectRevert(LiquidationModule.InvalidRepayAmount.selector);
        module.liquidate(emptyId, 1 ether, 0, 0);

        // maxRepay == 0 branch fallback to debt
        uint256 tinyId =
            vault.openPosition(user, poolId, address(token0), address(token1), -300, 300, 0, 1 ether, 1 ether);
        market.borrowFor(tinyId, address(this), 1);

        vm.prank(admin);
        module.setLiquidationParams(1, 0);

        token1.mint(liquidator, 1_000);
        vm.prank(liquidator);
        token1.approve(address(market), type(uint256).max);

        vm.prank(liquidator);
        (uint256 repaid,,,) = module.liquidate(tinyId, 1, 0, 0);
        assertEq(repaid, 1);
    }

    function testMinSeizeAndBadDebtForgivenessPath() public {
        MockLiquidationRisk mockRisk = new MockLiquidationRisk();
        vm.prank(admin);
        LiquidationModule module = new LiquidationModule(admin, vault, market, RiskManager(address(mockRisk)));

        vm.startPrank(admin);
        vault.setOperator(address(this), true);
        vault.setLiquidationModule(address(module));
        market.setBorrower(address(this), true);
        market.setRepayer(address(module), true);
        market.setLiquidationModule(address(module));
        vm.stopPrank();

        uint256 id = vault.openPosition(user, poolId, address(token0), address(token1), -300, 300, 0, 1 ether, 1 ether);
        market.borrowFor(id, address(this), 10_000 ether);

        token1.mint(liquidator, 20_000 ether);
        vm.prank(liquidator);
        token1.approve(address(market), type(uint256).max);

        vm.prank(admin);
        module.setLiquidationParams(500, DataTypes.BPS); // small repay, full seize

        vm.prank(liquidator);
        vm.expectRevert(LiquidationModule.InvalidRepayAmount.selector);
        module.liquidate(id, 1 ether, 10 ether, 10 ether);

        uint256 badDebtBefore = market.badDebt();

        vm.prank(liquidator);
        module.liquidate(id, 1 ether, 0, 0);

        // Remaining debt with no collateral triggers forgiveBadDebt in the module.
        assertEq(market.debtOf(id), 0);
        assertGt(market.badDebt(), badDebtBefore);
    }
}
