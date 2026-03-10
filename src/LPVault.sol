// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DataTypes} from "./libraries/DataTypes.sol";
import {ILPVault} from "./interfaces/ILPVault.sol";

contract LPVault is ILPVault, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOperator();
    error NotLiquidationModule();
    error InvalidPosition();
    error NotPositionOwner();
    error InactivePosition();

    event OperatorUpdated(address indexed operator, bool allowed);
    event LiquidationModuleUpdated(address indexed liquidationModule);
    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        bytes32 indexed poolId,
        uint256 collateral0,
        uint256 collateral1,
        uint128 baseLiquidity
    );
    event PositionUpdated(
        uint256 indexed positionId,
        uint256 collateral0,
        uint256 collateral1,
        uint128 baseLiquidity,
        uint128 leveragedLiquidity
    );
    event PositionSeized(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 seized0,
        uint256 seized1,
        uint128 seizedLiquidity
    );

    uint256 public nextPositionId = 1;
    address public liquidationModule;

    mapping(address => bool) public isOperator;
    mapping(uint256 => DataTypes.Position) private _positions;

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    modifier onlyLiquidationModule() {
        if (msg.sender != liquidationModule) revert NotLiquidationModule();
        _;
    }

    constructor(address admin) Ownable(admin) {}

    function setOperator(address operator, bool allowed) external onlyOwner {
        isOperator[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function setLiquidationModule(address module) external onlyOwner {
        liquidationModule = module;
        emit LiquidationModuleUpdated(module);
    }

    function ownerOf(uint256 positionId) external view returns (address) {
        return _positions[positionId].owner;
    }

    function position(uint256 positionId) external view returns (DataTypes.Position memory) {
        return _positions[positionId];
    }

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
    ) external onlyOperator nonReentrant returns (uint256 positionId) {
        if (owner == address(0) || token0 == address(0) || token1 == address(0) || token0 == token1) {
            revert InvalidPosition();
        }
        if (collateral0 == 0 && collateral1 == 0) revert InvalidPosition();

        positionId = nextPositionId++;

        _positions[positionId] = DataTypes.Position({
            owner: owner,
            poolId: poolId,
            token0: token0,
            token1: token1,
            tickLower: tickLower,
            tickUpper: tickUpper,
            baseLiquidity: baseLiquidity,
            leveragedLiquidity: 0,
            collateral0: collateral0,
            collateral1: collateral1,
            active: true
        });

        emit PositionOpened(positionId, owner, poolId, collateral0, collateral1, baseLiquidity);
    }

    function increaseLeverage(uint256 positionId, uint256 addCollateral0, uint256 addCollateral1, uint128 addLiquidity)
        external
        onlyOperator
        nonReentrant
    {
        DataTypes.Position storage p = _positions[positionId];
        if (p.owner == address(0)) revert InvalidPosition();
        if (!p.active) revert InactivePosition();

        p.collateral0 += addCollateral0;
        p.collateral1 += addCollateral1;
        p.leveragedLiquidity += addLiquidity;

        emit PositionUpdated(positionId, p.collateral0, p.collateral1, p.baseLiquidity, p.leveragedLiquidity);
    }

    function reducePosition(
        uint256 positionId,
        address receiver,
        uint256 withdraw0,
        uint256 withdraw1,
        uint128 reduceLiquidity
    ) external onlyOperator nonReentrant {
        DataTypes.Position storage p = _positions[positionId];
        if (p.owner == address(0)) revert InvalidPosition();
        if (!p.active) revert InactivePosition();
        if (receiver != p.owner) revert NotPositionOwner();

        if (withdraw0 > p.collateral0 || withdraw1 > p.collateral1) revert InvalidPosition();
        if (reduceLiquidity > p.leveragedLiquidity) revert InvalidPosition();

        p.collateral0 -= withdraw0;
        p.collateral1 -= withdraw1;
        p.leveragedLiquidity -= reduceLiquidity;

        if (withdraw0 > 0) IERC20(p.token0).safeTransfer(receiver, withdraw0);
        if (withdraw1 > 0) IERC20(p.token1).safeTransfer(receiver, withdraw1);

        _deactivateIfEmpty(p);

        emit PositionUpdated(positionId, p.collateral0, p.collateral1, p.baseLiquidity, p.leveragedLiquidity);
    }

    function seizeForLiquidation(uint256 positionId, address liquidator, uint256 repayFractionBps, uint256 bonusBps)
        external
        onlyLiquidationModule
        nonReentrant
        returns (uint256 seized0, uint256 seized1, uint128 seizedLiquidity)
    {
        DataTypes.Position storage p = _positions[positionId];
        if (p.owner == address(0)) revert InvalidPosition();
        if (!p.active) revert InactivePosition();

        uint256 seizeBps = repayFractionBps + bonusBps;
        if (seizeBps > DataTypes.BPS) seizeBps = DataTypes.BPS;

        seized0 = (p.collateral0 * seizeBps) / DataTypes.BPS;
        seized1 = (p.collateral1 * seizeBps) / DataTypes.BPS;
        seizedLiquidity = uint128((uint256(p.leveragedLiquidity) * seizeBps) / DataTypes.BPS);

        if (seized0 > p.collateral0) seized0 = p.collateral0;
        if (seized1 > p.collateral1) seized1 = p.collateral1;
        if (seizedLiquidity > p.leveragedLiquidity) seizedLiquidity = p.leveragedLiquidity;

        p.collateral0 -= seized0;
        p.collateral1 -= seized1;
        p.leveragedLiquidity -= seizedLiquidity;

        if (seized0 > 0) IERC20(p.token0).safeTransfer(liquidator, seized0);
        if (seized1 > 0) IERC20(p.token1).safeTransfer(liquidator, seized1);

        _deactivateIfEmpty(p);

        emit PositionSeized(positionId, liquidator, seized0, seized1, seizedLiquidity);
    }

    function _deactivateIfEmpty(DataTypes.Position storage p) private {
        if (p.collateral0 == 0 && p.collateral1 == 0 && p.baseLiquidity == 0 && p.leveragedLiquidity == 0) {
            p.active = false;
        }
    }
}
