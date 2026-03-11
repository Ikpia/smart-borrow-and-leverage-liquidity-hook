// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {BaseScript} from "./BaseScript.sol";

contract LiquidityHelpers is BaseScript {
    using CurrencyLibrary for Currency;

    struct MintInput {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
        address recipient;
        bytes hookData;
    }

    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory, bytes[] memory) {
        MintInput memory input = MintInput({
            poolKey: poolKey,
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            liquidity: liquidity,
            amount0Max: amount0Max,
            amount1Max: amount1Max,
            recipient: recipient,
            hookData: hookData
        });

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](4);
        params[0] = _encodeMint(input);
        params[1] = abi.encode(input.poolKey.currency0, input.poolKey.currency1);
        params[2] = abi.encode(input.poolKey.currency0, input.recipient);
        params[3] = abi.encode(input.poolKey.currency1, input.recipient);

        return (actions, params);
    }

    function _encodeMint(MintInput memory input) private pure returns (bytes memory) {
        return abi.encode(
            input.poolKey,
            input.tickLower,
            input.tickUpper,
            input.liquidity,
            input.amount0Max,
            input.amount1Max,
            input.recipient,
            input.hookData
        );
    }

    function tokenApprovals() public {
        if (!currency0.isAddressZero()) {
            token0.approve(address(permit2), type(uint256).max);
            permit2.approve(address(token0), address(positionManager), type(uint160).max, type(uint48).max);
        }

        if (!currency1.isAddressZero()) {
            token1.approve(address(permit2), type(uint256).max);
            permit2.approve(address(token1), address(positionManager), type(uint160).max, type(uint48).max);
        }
    }

    function truncateTickSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        /// forge-lint: disable-next-line(divide-before-multiply)
        return ((tick / tickSpacing) * tickSpacing);
    }
}
