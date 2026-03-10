// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DataTypes} from "../libraries/DataTypes.sol";

interface ILPVault {
    function ownerOf(uint256 positionId) external view returns (address);
    function position(uint256 positionId) external view returns (DataTypes.Position memory);

    function openPosition(
        address owner,
        bytes32 poolId,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint128 baseLiquidity,
        uint256 collateral0,
        uint256 collateral1
    ) external returns (uint256 positionId);

    function increaseLeverage(uint256 positionId, uint256 addCollateral0, uint256 addCollateral1, uint128 addLiquidity)
        external;

    function reducePosition(
        uint256 positionId,
        address receiver,
        uint256 withdraw0,
        uint256 withdraw1,
        uint128 reduceLiquidity
    ) external;

    function seizeForLiquidation(uint256 positionId, address liquidator, uint256 repayFractionBps, uint256 bonusBps)
        external
        returns (uint256 seized0, uint256 seized1, uint128 seizedLiquidity);
}
