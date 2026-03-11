// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";

import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {LPVault} from "../../src/LPVault.sol";

contract LPVaultUnitTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();

        vm.prank(admin);
        vault.setOperator(address(this), true);

        vm.prank(admin);
        vault.setLiquidationModule(address(this));

        token0.mint(address(vault), 2_000_000 ether);
        token1.mint(address(vault), 2_000_000 ether);
    }

    function testOpenPositionValidAndOwnerViews() public {
        uint256 positionId = _openPosition(10_000, 1_000 ether, 2_000 ether);

        assertEq(vault.ownerOf(positionId), user);
        DataTypes.Position memory p = vault.position(positionId);
        assertEq(p.owner, user);
        assertEq(p.poolId, poolId);
        assertEq(p.collateral0, 1_000 ether);
        assertEq(p.collateral1, 2_000 ether);
        assertTrue(p.active);
    }

    function testOpenPositionValidationReverts() public {
        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.openPosition(address(0), poolId, address(token0), address(token1), -100, 100, 1, 1, 1);

        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.openPosition(user, poolId, address(0), address(token1), -100, 100, 1, 1, 1);

        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.openPosition(user, poolId, address(token0), address(token0), -100, 100, 1, 1, 1);

        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.openPosition(user, poolId, address(token0), address(token1), -100, 100, 1, 0, 0);
    }

    function testOperatorAndLiquidationGuards() public {
        vm.startPrank(user);
        vm.expectRevert(LPVault.NotOperator.selector);
        vault.openPosition(user, poolId, address(token0), address(token1), -100, 100, 1, 1, 1);
        vm.stopPrank();

        vm.prank(admin);
        vault.setLiquidationModule(liquidator);
        vm.expectRevert(LPVault.NotLiquidationModule.selector);
        vault.seizeForLiquidation(1, liquidator, 5_000, 800);
    }

    function testIncreaseLeverageValidationAndInactive() public {
        uint256 positionId = _openPosition(0, 10 ether, 0);

        vault.increaseLeverage(positionId, 1 ether, 2 ether, 3);
        DataTypes.Position memory leveraged = vault.position(positionId);
        assertEq(leveraged.collateral0, 11 ether);
        assertEq(leveraged.collateral1, 2 ether);
        assertEq(leveraged.leveragedLiquidity, 3);

        vault.reducePosition(positionId, user, leveraged.collateral0, leveraged.collateral1, leveraged.leveragedLiquidity);
        DataTypes.Position memory emptied = vault.position(positionId);
        assertFalse(emptied.active);

        vm.expectRevert(LPVault.InactivePosition.selector);
        vault.increaseLeverage(positionId, 1, 1, 1);

        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.increaseLeverage(positionId + 999, 1, 1, 1);
    }

    function testReducePositionChecksAndTransfers() public {
        uint256 positionId = _openPosition(50, 500 ether, 800 ether);
        vault.increaseLeverage(positionId, 100 ether, 50 ether, 20);

        vm.expectRevert(LPVault.NotPositionOwner.selector);
        vault.reducePosition(positionId, liquidator, 1, 0, 0);

        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.reducePosition(positionId, user, type(uint256).max, 0, 0);

        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.reducePosition(positionId, user, 0, type(uint256).max, 0);

        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.reducePosition(positionId, user, 0, 0, type(uint128).max);

        uint256 user0Before = token0.balanceOf(user);
        uint256 user1Before = token1.balanceOf(user);

        vault.reducePosition(positionId, user, 200 ether, 300 ether, 10);

        DataTypes.Position memory p = vault.position(positionId);
        assertEq(p.collateral0, 400 ether);
        assertEq(p.collateral1, 550 ether);
        assertEq(p.leveragedLiquidity, 10);
        assertEq(token0.balanceOf(user), user0Before + 200 ether);
        assertEq(token1.balanceOf(user), user1Before + 300 ether);
        assertTrue(p.active);
    }

    function testReducePositionInvalidAndInactivePaths() public {
        uint256 id = _openPosition(0, 1 ether, 0);
        vault.reducePosition(id, user, 1 ether, 0, 0);

        vm.expectRevert(LPVault.InactivePosition.selector);
        vault.reducePosition(id, user, 0, 0, 0);

        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.reducePosition(id + 111, user, 0, 0, 0);
    }

    function testSeizeForLiquidationClampsAndDeactivates() public {
        uint256 id = _openPosition(0, 100 ether, 200 ether);
        vault.increaseLeverage(id, 0, 0, 100);

        uint256 liquidator0Before = token0.balanceOf(liquidator);
        uint256 liquidator1Before = token1.balanceOf(liquidator);

        (uint256 seized0, uint256 seized1, uint128 seizedLiq) = vault.seizeForLiquidation(id, liquidator, 9_000, 2_000);

        assertEq(seized0, 100 ether);
        assertEq(seized1, 200 ether);
        assertEq(seizedLiq, 100);
        assertEq(token0.balanceOf(liquidator), liquidator0Before + seized0);
        assertEq(token1.balanceOf(liquidator), liquidator1Before + seized1);

        DataTypes.Position memory p = vault.position(id);
        assertEq(p.collateral0, 0);
        assertEq(p.collateral1, 0);
        assertEq(p.leveragedLiquidity, 0);
        assertFalse(p.active);
    }

    function testSeizeForLiquidationInvalidAndInactivePaths() public {
        vm.expectRevert(LPVault.InvalidPosition.selector);
        vault.seizeForLiquidation(123_456, liquidator, 1_000, 500);

        uint256 id = _openPosition(0, 1 ether, 0);
        vault.reducePosition(id, user, 1 ether, 0, 0);

        vm.expectRevert(LPVault.InactivePosition.selector);
        vault.seizeForLiquidation(id, liquidator, 1_000, 500);
    }

    function _openPosition(uint128 baseLiquidity, uint256 collateral0, uint256 collateral1)
        internal
        returns (uint256 positionId)
    {
        positionId = vault.openPosition(
            user,
            poolId,
            address(token0),
            address(token1),
            -600,
            600,
            baseLiquidity,
            collateral0,
            collateral1
        );
    }
}
