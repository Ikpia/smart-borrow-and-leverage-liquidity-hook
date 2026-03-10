// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {Deployers} from "test/utils/Deployers.sol";
import {EasyPosm} from "test/utils/libraries/EasyPosm.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {MockFlashLoanProvider} from "../../src/mocks/MockFlashLoanProvider.sol";
import {LeverageLiquidityHook} from "../../src/hooks/LeverageLiquidityHook.sol";
import {LPVault} from "../../src/LPVault.sol";
import {BorrowingMarket} from "../../src/markets/BorrowingMarket.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {LiquidationModule} from "../../src/modules/LiquidationModule.sol";
import {FlashLeverageModule} from "../../src/modules/FlashLeverageModule.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

abstract contract DemoShared is Script, Deployers {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;

    struct Deployed {
        MockToken token0;
        MockToken token1;
        LeverageLiquidityHook hook;
        LPVault vault;
        BorrowingMarket market;
        RiskManager risk;
        LeverageRouter router;
        LiquidationModule liquidation;
        MockFlashLoanProvider flashProvider;
        FlashLeverageModule flashModule;
        PoolKey poolKey;
        bytes32 poolId;
    }

    function _etch(address target, bytes memory bytecode) internal override {
        if (block.chainid == 31337) {
            vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '",', '"', vm.toString(bytecode), '"]'));
        } else {
            revert("unsupported etch");
        }
    }

    function _deployAll(uint256 deployerPk) internal returns (Deployed memory d) {
        deployArtifacts();
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        d.token0 = new MockToken("Demo Token0", "DT0", 18);
        d.token1 = new MockToken("Demo Token1", "DT1", 18);
        if (address(d.token0) > address(d.token1)) {
            (d.token0, d.token1) = (d.token1, d.token0);
        }

        d.token0.mint(deployer, 2_000_000 ether);
        d.token1.mint(deployer, 2_000_000 ether);

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(LeverageLiquidityHook).creationCode, constructorArgs);

        d.hook = new LeverageLiquidityHook{salt: salt}(poolManager);
        require(address(d.hook) == hookAddress, "hook address mismatch");

        d.poolKey = PoolKey({
            currency0: Currency.wrap(address(d.token0)),
            currency1: Currency.wrap(address(d.token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(d.hook))
        });
        d.poolId = PoolId.unwrap(d.poolKey.toId());

        poolManager.initialize(d.poolKey, Constants.SQRT_PRICE_1_1);

        d.token0.approve(address(permit2), type(uint256).max);
        d.token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(d.token0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(d.token1), address(positionManager), type(uint160).max, type(uint48).max);

        int24 tickLower = TickMath.minUsableTick(d.poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(d.poolKey.tickSpacing);
        uint128 liquidityAmount = 300_000;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            d.poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            deployer,
            block.timestamp,
            Constants.ZERO_BYTES
        );

        d.vault = new LPVault(deployer);
        d.market = new BorrowingMarket(address(d.token1), deployer);
        d.risk = new RiskManager(deployer, d.vault, d.market, d.hook);
        d.router = new LeverageRouter(d.vault, d.market, d.risk);
        d.liquidation = new LiquidationModule(deployer, d.vault, d.market, d.risk);
        d.flashProvider = new MockFlashLoanProvider(deployer);
        d.flashModule =
            new FlashLeverageModule(deployer, d.vault, d.market, d.risk, d.hook, d.flashProvider, 500_000 ether);

        d.vault.setOperator(address(d.router), true);
        d.vault.setOperator(address(d.flashModule), true);
        d.vault.setLiquidationModule(address(d.liquidation));

        d.market.setBorrower(address(d.router), true);
        d.market.setBorrower(address(d.flashModule), true);
        d.market.setRepayer(address(d.router), true);
        d.market.setRepayer(address(d.liquidation), true);
        d.market.setLiquidationModule(address(d.liquidation));

        d.token1.approve(address(d.market), type(uint256).max);
        d.market.supply(1_000_000 ether, deployer);

        DataTypes.PoolRiskConfig memory cfg = DataTypes.PoolRiskConfig({
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
        d.risk.setPoolRiskConfig(d.poolId, cfg);

        vm.stopBroadcast();

        console2.log("deployed hook", address(d.hook));
        console2.log("deployed vault", address(d.vault));
        console2.log("deployed market", address(d.market));
        console2.log("deployed risk", address(d.risk));
        console2.log("deployed router", address(d.router));
        console2.log("deployed liquidation", address(d.liquidation));
        console2.log("deployed flash module", address(d.flashModule));
        console2.log("token0", address(d.token0));
        console2.log("token1", address(d.token1));
        console2.logBytes32(d.poolId);
    }

    function _openLeverage(uint256 actorPk, Deployed memory d, uint256 borrowAmount, uint128 leveragedLiquidity)
        internal
        returns (uint256 positionId)
    {
        address actor = vm.addr(actorPk);
        vm.startBroadcast(actorPk);

        d.token0.mint(actor, 300_000 ether);
        d.token1.mint(actor, 300_000 ether);
        d.token0.approve(address(d.router), type(uint256).max);
        d.token1.approve(address(d.router), type(uint256).max);

        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: d.poolKey,
            tickLower: -900,
            tickUpper: 900,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: borrowAmount,
            leveragedLiquidity: leveragedLiquidity,
            minHealthFactorWad: 1e18
        });

        positionId = d.router.openBorrowAndReinvest(p);
        vm.stopBroadcast();

        console2.log("position id", positionId);
        console2.log("debt", d.market.debtOf(positionId));
        console2.log("health", d.risk.healthFactorWad(positionId));
    }

    function _stressAndLiquidate(uint256 liquidatorPk, Deployed memory d, uint256 positionId) internal {
        address liquidator = vm.addr(liquidatorPk);

        vm.startBroadcast(liquidatorPk);
        d.token1.mint(liquidator, 500_000 ether);
        d.token1.approve(address(d.market), type(uint256).max);
        vm.stopBroadcast();

        // apply deterministic stress via hook sync after aggressive swaps
        vm.startBroadcast(liquidatorPk);
        d.hook.syncPool(d.poolKey);
        vm.stopBroadcast();

        // tighten config for deterministic liquidation demo
        DataTypes.PoolRiskConfig memory cfg = DataTypes.PoolRiskConfig({
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

        vm.startBroadcast(liquidatorPk);
        d.risk.setPoolRiskConfig(d.poolId, cfg);
        d.liquidation.liquidate(positionId, 30_000 ether, 0, 0);
        vm.stopBroadcast();

        console2.log("post-liquidation debt", d.market.debtOf(positionId));
        console2.log("post-liquidation health", d.risk.healthFactorWad(positionId));
    }
}
