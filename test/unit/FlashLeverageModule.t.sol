// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";

import {MockToken} from "../../src/mocks/MockToken.sol";
import {MockFlashLoanProvider} from "../../src/mocks/MockFlashLoanProvider.sol";
import {BorrowingMarket} from "../../src/markets/BorrowingMarket.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {FlashLeverageModule} from "../../src/modules/FlashLeverageModule.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract FlashLeverageModuleUnitTest is ProtocolFixture {
    function setUp() public {
        setUpFixture();
    }

    function testFlashLeverageMaxFlashAndOwnerGuards() public {
        uint256 id = _openBasePosition();

        vm.prank(user);
        vm.expectRevert(FlashLeverageModule.MaxFlashExceeded.selector);
        flashModule.flashLeverage(id, 0, 0, 1e18, 1_000);

        uint256 maxFlash = flashModule.maxFlashAmount();
        vm.prank(user);
        vm.expectRevert(FlashLeverageModule.MaxFlashExceeded.selector);
        flashModule.flashLeverage(id, maxFlash + 1, 0, 1e18, 1_000);

        vm.prank(liquidator);
        vm.expectRevert(FlashLeverageModule.NotPositionOwner.selector);
        flashModule.flashLeverage(id, 1 ether, 1, 1e18, 1_000);
    }

    function testSetMaxFlashAmountAndHealthGuard() public {
        vm.prank(admin);
        flashModule.setMaxFlashAmount(100_000 ether);
        assertEq(flashModule.maxFlashAmount(), 100_000 ether);

        uint256 id = _openBasePosition();

        vm.prank(user);
        vm.expectRevert(FlashLeverageModule.HealthFactorTooLow.selector);
        flashModule.flashLeverage(id, 1_000 ether, 10, type(uint256).max, 10_000);
    }

    function testTickBoundAndNotFlashProviderReverts() public {
        uint256 id = _openBasePosition();
        metricsHook.setPoolMetrics(poolId, 10_000, 10, 100_000);

        vm.prank(user);
        vm.expectRevert(FlashLeverageModule.TickBoundExceeded.selector);
        flashModule.flashLeverage(id, 1_000 ether, 10, 1e18, 10);

        bytes memory data = abi.encode(
            FlashLeverageModule.FlashLeverageData({
                positionId: id,
                owner: user,
                addLiquidity: 0,
                minHealthFactorWad: 1e18,
                maxTickDistance: 20_000
            })
        );

        vm.expectRevert(FlashLeverageModule.NotFlashProvider.selector);
        flashModule.onFlashLoan(address(this), address(token1), 1 ether, 0, data);
    }

    function testCallbackOwnerMismatchReverts() public {
        uint256 id = _openBasePosition();

        bytes memory data = abi.encode(
            FlashLeverageModule.FlashLeverageData({
                positionId: id,
                owner: liquidator,
                addLiquidity: 0,
                minHealthFactorWad: 1e18,
                maxTickDistance: 20_000
            })
        );

        token1.mint(address(flashModule), 1 ether);

        vm.prank(address(flashProvider));
        vm.expectRevert(FlashLeverageModule.NotPositionOwner.selector);
        flashModule.onFlashLoan(address(this), address(token1), 1 ether, 0, data);
    }

    function testInvalidBorrowAssetInsideCallback() public {
        uint256 id = _openBasePosition();

        MockToken token2 = new MockToken("BorrowX", "BRWX", 18);
        vm.prank(admin);
        BorrowingMarket marketX = new BorrowingMarket(address(token2), admin);
        vm.prank(admin);
        RiskManager riskX = new RiskManager(admin, vault, marketX, metricsHook);
        vm.prank(admin);
        MockFlashLoanProvider providerX = new MockFlashLoanProvider(admin);

        vm.prank(admin);
        FlashLeverageModule moduleX =
            new FlashLeverageModule(admin, vault, marketX, riskX, metricsHook, providerX, 100_000 ether);

        vm.startPrank(admin);
        vault.setOperator(address(moduleX), true);
        marketX.setBorrower(address(moduleX), true);
        marketX.setRepayer(address(moduleX), true);
        vm.stopPrank();

        token2.mint(address(moduleX), 1_000 ether);

        bytes memory data = abi.encode(
            FlashLeverageModule.FlashLeverageData({
                positionId: id,
                owner: user,
                addLiquidity: 100,
                minHealthFactorWad: 1e18,
                maxTickDistance: 20_000
            })
        );

        vm.prank(address(providerX));
        vm.expectRevert(FlashLeverageModule.InvalidBorrowAsset.selector);
        moduleX.onFlashLoan(address(this), address(token2), 1_000 ether, 0, data);
    }

    function testFlashLeverageWithNegativeTickDiffPath() public {
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: poolKey,
            tickLower: 500,
            tickUpper: 1_500,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: 0,
            leveragedLiquidity: 0,
            minHealthFactorWad: 1e18
        });

        vm.prank(user);
        uint256 positionId = router.openBorrowAndReinvest(p);

        // currentTick (0) is below center (1_000), forcing negative diff branch in _absTickDiff.
        metricsHook.setPoolMetrics(poolId, 0, 20, 200_000);

        vm.prank(user);
        flashModule.flashLeverage(positionId, 1_000 ether, 100, 1e18, 5_000);
    }

    function testCallbackToken0IncreaseBranch() public {
        uint256 id = _openBasePosition();

        bytes memory data = abi.encode(
            FlashLeverageModule.FlashLeverageData({
                positionId: id,
                owner: user,
                addLiquidity: 100,
                minHealthFactorWad: 1e18,
                maxTickDistance: 20_000
            })
        );

        uint256 amount = 1_000 ether;
        // The callback transfers `amount` into the vault, then repays `amount + fee` to provider.
        // Since token0 is not the borrow asset for this module, pre-fund token0 for repayment leg.
        token0.mint(address(flashModule), amount * 2);

        vm.prank(address(flashProvider));
        bytes32 response = flashModule.onFlashLoan(address(this), address(token0), amount, 0, data);

        assertEq(response, flashModule.CALLBACK_SUCCESS());
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
}
