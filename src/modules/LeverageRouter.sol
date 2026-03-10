// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DataTypes} from "../libraries/DataTypes.sol";
import {ILPVault} from "../interfaces/ILPVault.sol";
import {IBorrowingMarket} from "../interfaces/IBorrowingMarket.sol";
import {RiskManager} from "../RiskManager.sol";

contract LeverageRouter is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    error NotPositionOwner();
    error BorrowLimitExceeded();
    error InvalidBorrowAsset();
    error HealthFactorTooLow(uint256 currentHealth, uint256 minHealth);

    event PositionOpenedAndLeveraged(
        uint256 indexed positionId,
        address indexed owner,
        bytes32 indexed poolId,
        uint256 collateral0,
        uint256 collateral1,
        uint256 borrowAmount,
        uint128 leveragedLiquidity,
        uint256 healthFactorWad
    );

    event PositionLeveraged(
        uint256 indexed positionId,
        uint256 borrowAmount,
        uint128 liquidityAdded,
        uint256 healthFactorWad
    );

    event PositionRepaidAndUnwound(
        uint256 indexed positionId,
        uint256 repaid,
        uint256 withdrawn0,
        uint256 withdrawn1,
        uint128 liquidityReduced,
        uint256 healthFactorWad
    );

    ILPVault public immutable vault;
    IBorrowingMarket public immutable market;
    RiskManager public immutable riskManager;
    address public immutable borrowAsset;

    struct OpenPositionParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 baseLiquidity;
        uint256 collateral0;
        uint256 collateral1;
        uint256 borrowAmount;
        uint128 leveragedLiquidity;
        uint256 minHealthFactorWad;
    }

    constructor(ILPVault vault_, IBorrowingMarket market_, RiskManager riskManager_) {
        vault = vault_;
        market = market_;
        riskManager = riskManager_;
        borrowAsset = market_.borrowToken();
    }

    function openBorrowAndReinvest(OpenPositionParams calldata params)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        (address token0, address token1, bytes32 poolId) = _poolAssets(params.key);
        _transferCollateralIn(msg.sender, token0, token1, params.collateral0, params.collateral1);

        positionId = vault.openPosition(
            msg.sender,
            poolId,
            token0,
            token1,
            params.tickLower,
            params.tickUpper,
            params.baseLiquidity,
            params.collateral0,
            params.collateral1
        );

        if (params.borrowAmount > 0) {
            _borrowAndReinvest(positionId, params.borrowAmount, params.leveragedLiquidity, params.minHealthFactorWad);
        }

        uint256 hf = riskManager.healthFactorWad(positionId);

        emit PositionOpenedAndLeveraged(
            positionId,
            msg.sender,
            poolId,
            params.collateral0,
            params.collateral1,
            params.borrowAmount,
            params.leveragedLiquidity,
            hf
        );
    }

    function borrowAndReinvest(uint256 positionId, uint256 borrowAmount, uint128 addLiquidity, uint256 minHealthFactorWad)
        external
        nonReentrant
    {
        DataTypes.Position memory p = vault.position(positionId);
        if (p.owner != msg.sender) revert NotPositionOwner();

        _borrowAndReinvest(positionId, borrowAmount, addLiquidity, minHealthFactorWad);

        uint256 hf = riskManager.healthFactorWad(positionId);
        emit PositionLeveraged(positionId, borrowAmount, addLiquidity, hf);
    }

    function repayAndUnwind(
        uint256 positionId,
        uint256 repayAmount,
        uint256 withdraw0,
        uint256 withdraw1,
        uint128 reduceLiquidity
    ) external nonReentrant returns (uint256 repaid) {
        DataTypes.Position memory p = vault.position(positionId);
        if (p.owner != msg.sender) revert NotPositionOwner();

        if (repayAmount > 0) {
            repaid = market.repayFor(positionId, msg.sender, repayAmount);
        }

        if (withdraw0 > 0 || withdraw1 > 0 || reduceLiquidity > 0) {
            vault.reducePosition(positionId, msg.sender, withdraw0, withdraw1, reduceLiquidity);
        }

        uint256 debtLeft = market.debtOf(positionId);
        uint256 hf = riskManager.healthFactorWad(positionId);

        if (debtLeft > 0 && hf < DataTypes.WAD) {
            revert HealthFactorTooLow(hf, DataTypes.WAD);
        }

        emit PositionRepaidAndUnwound(positionId, repaid, withdraw0, withdraw1, reduceLiquidity, hf);
    }

    function repayAllAndWithdraw(uint256 positionId) external nonReentrant {
        DataTypes.Position memory p = vault.position(positionId);
        if (p.owner != msg.sender) revert NotPositionOwner();

        uint256 debt = market.debtOf(positionId);
        if (debt > 0) {
            market.repayFor(positionId, msg.sender, debt);
        }

        vault.reducePosition(positionId, msg.sender, p.collateral0, p.collateral1, p.leveragedLiquidity);

        emit PositionRepaidAndUnwound(positionId, debt, p.collateral0, p.collateral1, p.leveragedLiquidity, type(uint256).max);
    }

    function _borrowAndReinvest(uint256 positionId, uint256 borrowAmount, uint128 addLiquidity, uint256 minHealthFactorWad)
        internal
    {
        if (!riskManager.canBorrow(positionId, borrowAmount)) revert BorrowLimitExceeded();

        market.borrowFor(positionId, address(vault), borrowAmount);

        DataTypes.Position memory p = vault.position(positionId);
        if (borrowAsset == p.token0) {
            vault.increaseLeverage(positionId, borrowAmount, 0, addLiquidity);
        } else if (borrowAsset == p.token1) {
            vault.increaseLeverage(positionId, 0, borrowAmount, addLiquidity);
        } else {
            revert InvalidBorrowAsset();
        }

        uint256 hf = riskManager.healthFactorWad(positionId);
        if (hf < minHealthFactorWad) {
            revert HealthFactorTooLow(hf, minHealthFactorWad);
        }
    }

    function _poolAssets(PoolKey calldata key) internal pure returns (address token0, address token1, bytes32 poolId) {
        token0 = Currency.unwrap(key.currency0);
        token1 = Currency.unwrap(key.currency1);
        poolId = PoolId.unwrap(key.toId());
    }

    function _transferCollateralIn(
        address payer,
        address token0,
        address token1,
        uint256 collateral0,
        uint256 collateral1
    ) internal {
        if (collateral0 > 0) {
            IERC20(token0).safeTransferFrom(payer, address(vault), collateral0);
        }
        if (collateral1 > 0) {
            IERC20(token1).safeTransferFrom(payer, address(vault), collateral1);
        }
    }
}
