// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DemoShared} from "./DemoShared.sol";

contract DemoLeverageOnlyScript is DemoShared {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 userPk = vm.envOr("USER_PRIVATE_KEY", deployerPk);

        Deployed memory d = _deployAll(deployerPk);
        uint256 positionId = _openLeverage(userPk, d, 40_000 ether, 15_000);

        vm.startBroadcast(userPk);
        d.token1.approve(address(d.market), type(uint256).max);
        d.router.repayAndUnwind(positionId, 20_000 ether, 5_000 ether, 5_000 ether, 1_000);
        vm.stopBroadcast();
    }
}
