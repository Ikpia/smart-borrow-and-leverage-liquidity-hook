// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {MockToken} from "../../src/mocks/MockToken.sol";
import {LeverageLiquidityHook} from "../../src/hooks/LeverageLiquidityHook.sol";
import {LPVault} from "../../src/LPVault.sol";
import {BorrowingMarket} from "../../src/markets/BorrowingMarket.sol";
import {RiskManager} from "../../src/RiskManager.sol";
import {LeverageRouter} from "../../src/modules/LeverageRouter.sol";
import {LiquidationModule} from "../../src/modules/LiquidationModule.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

contract DemoUsingDeploymentScript is Script {
    using PoolIdLibrary for PoolKey;

    struct DeployedRefs {
        MockToken token0;
        MockToken token1;
        LeverageLiquidityHook hook;
        LPVault vault;
        BorrowingMarket market;
        RiskManager risk;
        LeverageRouter router;
        LiquidationModule liquidation;
        uint24 fee;
        int24 tickSpacing;
    }

    function run() external {
        uint256 ownerPk = vm.envUint("PRIVATE_KEY");
        uint256 userPk = vm.envOr("USER_PRIVATE_KEY", ownerPk);
        uint256 liquidatorPk = vm.envOr("LIQUIDATOR_PRIVATE_KEY", ownerPk);
        bool runRepayPath = vm.envOr("DEMO_RUN_REPAY", true);
        bool runLiquidationPath = vm.envOr("DEMO_RUN_LIQUIDATION", true);

        DeployedRefs memory d = _loadRefs();
        PoolKey memory key = _poolKey(d);
        bytes32 poolId = PoolId.unwrap(key.toId());

        address owner = vm.addr(ownerPk);
        address user = vm.addr(userPk);
        address liquidator = vm.addr(liquidatorPk);

        console2.log("demo owner", owner);
        console2.log("demo user", user);
        console2.log("demo liquidator", liquidator);
        console2.log("pool id");
        console2.logBytes32(poolId);

        // Reset to a known baseline config so repeated demo runs stay deterministic.
        DataTypes.PoolRiskConfig memory normalCfg = DataTypes.PoolRiskConfig({
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
        vm.startBroadcast(ownerPk);
        d.risk.setPoolRiskConfig(poolId, normalCfg);
        vm.stopBroadcast();

        // User perspective: prep balances and approvals for one-click leverage and unwind.
        vm.startBroadcast(userPk);
        d.token0.mint(user, 600_000 ether);
        d.token1.mint(user, 600_000 ether);
        d.token0.approve(address(d.router), type(uint256).max);
        d.token1.approve(address(d.router), type(uint256).max);
        d.token1.approve(address(d.market), type(uint256).max);
        vm.stopBroadcast();

        uint256 positionCore = _openPosition(userPk, d, key, 40_000 ether, 15_000, 1e18);
        _logPositionState(d, positionCore, "after_open_core");

        if (runRepayPath) {
            vm.startBroadcast(userPk);
            d.router.repayAndUnwind(positionCore, 20_000 ether, 5_000 ether, 5_000 ether, 1_000);
            vm.stopBroadcast();
            _logPositionState(d, positionCore, "after_partial_repay_unwind");

            vm.startBroadcast(userPk);
            d.router.repayAllAndWithdraw(positionCore);
            vm.stopBroadcast();
            _logPositionState(d, positionCore, "after_full_unwind");
        }

        if (runLiquidationPath) {
            uint256 positionLiq = _openPosition(userPk, d, key, 60_000 ether, 20_000, 1e18);
            _logPositionState(d, positionLiq, "before_liquidation");

            vm.startBroadcast(liquidatorPk);
            d.token1.mint(liquidator, 500_000 ether);
            d.token1.approve(address(d.market), type(uint256).max);
            d.hook.syncPool(key);
            vm.stopBroadcast();

            DataTypes.PoolRiskConfig memory cfg = DataTypes.PoolRiskConfig({
                enabled: true,
                stablePool: false,
                baseLtvBps: 2_000,
                liquidationLtvBps: 2_500,
                minLtvBps: 1_500,
                baseCollateralFactorBps: 4_000,
                minCollateralFactorBps: 3_500,
                maxVolatilityPenaltyBps: 0,
                maxDepthPenaltyBps: 0,
                maxDistancePenaltyBps: 0,
                maxRangePenaltyBps: 0,
                targetDepthLiquidity: 0,
                maxVolatilityEwma: 1,
                maxCenterDistance: 1,
                minRangeWidth: 1
            });

            vm.startBroadcast(ownerPk);
            d.risk.setPoolRiskConfig(poolId, cfg);
            vm.stopBroadcast();

            vm.startBroadcast(liquidatorPk);
            d.liquidation.liquidate(positionLiq, 30_000 ether, 0, 0);
            vm.stopBroadcast();

            _logPositionState(d, positionLiq, "after_liquidation");
        }
    }

    function _openPosition(
        uint256 userPk,
        DeployedRefs memory d,
        PoolKey memory key,
        uint256 borrowAmount,
        uint128 leveragedLiquidity,
        uint256 minHealthFactor
    ) internal returns (uint256 positionId) {
        vm.startBroadcast(userPk);
        LeverageRouter.OpenPositionParams memory p = LeverageRouter.OpenPositionParams({
            key: key,
            tickLower: -900,
            tickUpper: 900,
            baseLiquidity: 100_000,
            collateral0: 100_000 ether,
            collateral1: 100_000 ether,
            borrowAmount: borrowAmount,
            leveragedLiquidity: leveragedLiquidity,
            minHealthFactorWad: minHealthFactor
        });
        positionId = d.router.openBorrowAndReinvest(p);
        vm.stopBroadcast();

        console2.log("opened position", positionId);
    }

    function _loadRefs() internal view returns (DeployedRefs memory d) {
        d.token0 = MockToken(vm.envAddress("DEPLOYED_TOKEN0_ADDRESS"));
        d.token1 = MockToken(vm.envAddress("DEPLOYED_TOKEN1_ADDRESS"));
        d.hook = LeverageLiquidityHook(vm.envAddress("DEPLOYED_HOOK_ADDRESS"));
        d.vault = LPVault(vm.envAddress("DEPLOYED_VAULT_ADDRESS"));
        d.market = BorrowingMarket(vm.envAddress("DEPLOYED_MARKET_ADDRESS"));
        d.risk = RiskManager(vm.envAddress("DEPLOYED_RISK_MANAGER_ADDRESS"));
        d.router = LeverageRouter(vm.envAddress("DEPLOYED_ROUTER_ADDRESS"));
        d.liquidation = LiquidationModule(vm.envAddress("DEPLOYED_LIQUIDATION_MODULE_ADDRESS"));
        d.fee = uint24(vm.envOr("DEPLOYED_POOL_FEE", uint256(3000)));
        d.tickSpacing = int24(int256(vm.envOr("DEPLOYED_POOL_TICK_SPACING", uint256(60))));
    }

    function _poolKey(DeployedRefs memory d) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(d.token0)),
            currency1: Currency.wrap(address(d.token1)),
            fee: d.fee,
            tickSpacing: d.tickSpacing,
            hooks: IHooks(address(d.hook))
        });
    }

    function _logPositionState(DeployedRefs memory d, uint256 positionId, string memory label) internal view {
        DataTypes.RiskSnapshot memory s = d.risk.snapshot(positionId);
        console2.log(label);
        console2.log("position", positionId);
        console2.log("debt", d.market.debtOf(positionId));
        console2.log("health_wad", s.healthFactorWad);
        console2.log("max_borrow_quote", s.maxBorrowQuote);
        console2.log("liquidation_value_quote", s.liquidationValueQuote);
    }
}
