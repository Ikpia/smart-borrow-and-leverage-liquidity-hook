// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract LeverageRouterUnitTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();
    }

    function testOpenBorrowAndReinvestFlow() public {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -900,
            tickUpper: 900,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: 50_000 ether,
            leveragedLiquidity: 25_000,
            minHealthFactorWad: 1e18
        });

        vm.prank(user);
        uint256 positionId = router.openBorrowAndReinvest(p);

        DataTypes.Position memory pos = vault.position(positionId);

        assertEq(pos.collateral1, 150_000 ether);
        assertEq(pos.leveragedLiquidity, 25_000);
        assertEq(market.debtOf(positionId), 50_000 ether);
    }

    function testBorrowBeyondLimitReverts() public {
        uint256 positionId = _openConservativePosition();

        vm.prank(user);
        vm.expectRevert();
        router.borrowAndReinvest(positionId, 3_000_000 ether, 1_000, 1e18);
    }

    function testRepayAndPartialUnwind() public {
        uint256 positionId = _openConservativePosition();

        vm.prank(user);
        router.borrowAndReinvest(positionId, 25_000 ether, 8_000, 1e18);

        uint256 debtBefore = market.debtOf(positionId);

        vm.prank(user);
        router.repayAndUnwind(positionId, 10_000 ether, 5_000 ether, 5_000 ether, 1_000);

        DataTypes.Position memory p = vault.position(positionId);
        uint256 debtAfter = market.debtOf(positionId);

        assertLt(debtAfter, debtBefore);
        assertEq(p.collateral0, 95_000 ether);
        assertEq(p.collateral1, 120_000 ether);
    }

    function _openConservativePosition() internal returns (uint256 positionId) {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: -1_200,
            tickUpper: 1_200,
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
