// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

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

contract DeployProtocolUnichainScript is Script {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address owner = vm.envAddress("OWNER_ADDRESS");
        require(owner == deployer, "OWNER_ADDRESS must match PRIVATE_KEY");

        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));

        vm.startBroadcast(deployerPk);

        MockToken token0 = new MockToken("Demo Token0", "DT0", 18);
        MockToken token1 = new MockToken("Demo Token1", "DT1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        token0.mint(deployer, 2_000_000 ether);
        token1.mint(deployer, 2_000_000 ether);

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(LeverageLiquidityHook).creationCode, constructorArgs);

        LeverageLiquidityHook hook = new LeverageLiquidityHook{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "hook address mismatch");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        bytes32 poolId = PoolId.unwrap(key.toId());

        poolManager.initialize(key, SQRT_PRICE_1_1);

        LPVault vault = new LPVault(deployer);
        BorrowingMarket market = new BorrowingMarket(address(token1), deployer);
        RiskManager risk = new RiskManager(deployer, vault, market, hook);
        LeverageRouter router = new LeverageRouter(vault, market, risk);
        LiquidationModule liquidation = new LiquidationModule(deployer, vault, market, risk);
        MockFlashLoanProvider flashProvider = new MockFlashLoanProvider(deployer);
        FlashLeverageModule flashModule =
            new FlashLeverageModule(deployer, vault, market, risk, hook, flashProvider, 500_000 ether);

        vault.setOperator(address(router), true);
        vault.setOperator(address(flashModule), true);
        vault.setLiquidationModule(address(liquidation));

        market.setBorrower(address(router), true);
        market.setBorrower(address(flashModule), true);
        market.setRepayer(address(router), true);
        market.setRepayer(address(liquidation), true);
        market.setLiquidationModule(address(liquidation));

        token1.approve(address(market), type(uint256).max);
        market.supply(1_000_000 ether, deployer);

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
        risk.setPoolRiskConfig(poolId, cfg);

        vm.stopBroadcast();

        console2.log("deployed hook", address(hook));
        console2.log("deployed vault", address(vault));
        console2.log("deployed market", address(market));
        console2.log("deployed risk", address(risk));
        console2.log("deployed router", address(router));
        console2.log("deployed liquidation", address(liquidation));
        console2.log("deployed flash module", address(flashModule));
        console2.log("token0", address(token0));
        console2.log("token1", address(token1));
        console2.log("pool id");
        console2.logBytes32(poolId);
    }
}
