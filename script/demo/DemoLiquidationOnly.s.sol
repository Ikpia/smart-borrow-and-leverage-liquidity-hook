// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DemoShared} from "./DemoShared.sol";

contract DemoLiquidationOnlyScript is DemoShared {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 userPk = vm.envOr("USER_PRIVATE_KEY", deployerPk);
        uint256 liquidatorPk = vm.envOr("LIQUIDATOR_PRIVATE_KEY", deployerPk);

        Deployed memory d = _deployAll(deployerPk);
        uint256 positionId = _openLeverage(userPk, d, 60_000 ether, 20_000);
        _stressAndLiquidate(liquidatorPk, d, positionId);
    }
}
