// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DemoShared} from "../demo/DemoShared.sol";

contract DeployProtocolScript is DemoShared {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        _deployAll(deployerPk);
    }
}
