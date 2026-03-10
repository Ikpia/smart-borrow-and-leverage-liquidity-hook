// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DataTypes} from "../libraries/DataTypes.sol";
import {ILPVault} from "../interfaces/ILPVault.sol";
import {IBorrowingMarket} from "../interfaces/IBorrowingMarket.sol";
import {RiskManager} from "../RiskManager.sol";

contract LiquidationModule is Ownable2Step, ReentrancyGuard {
    error PositionHealthy();
    error InvalidRepayAmount();

    event LiquidationParamsUpdated(uint256 closeFactorBps, uint256 liquidationBonusBps);
    event PositionLiquidated(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 repaid,
        uint256 seized0,
        uint256 seized1,
        uint128 seizedLiquidity,
        bool badDebtForgiven
    );

    ILPVault public immutable vault;
    IBorrowingMarket public immutable market;
    RiskManager public immutable riskManager;

    uint256 public closeFactorBps = 5_000;
    uint256 public liquidationBonusBps = 800;

    constructor(address admin, ILPVault vault_, IBorrowingMarket market_, RiskManager riskManager_) Ownable(admin) {
        vault = vault_;
        market = market_;
        riskManager = riskManager_;
    }

    function setLiquidationParams(uint256 closeFactor, uint256 bonus) external onlyOwner {
        if (closeFactor == 0 || closeFactor > DataTypes.BPS || bonus > DataTypes.BPS) revert InvalidRepayAmount();
        closeFactorBps = closeFactor;
        liquidationBonusBps = bonus;
        emit LiquidationParamsUpdated(closeFactor, bonus);
    }

    function liquidate(uint256 positionId, uint256 repayAmount, uint256 minSeized0, uint256 minSeized1)
        external
        nonReentrant
        returns (uint256 repaid, uint256 seized0, uint256 seized1, uint128 seizedLiquidity)
    {
        if (!riskManager.isLiquidatable(positionId)) revert PositionHealthy();

        uint256 debt = market.debtOf(positionId);
        if (debt == 0) revert InvalidRepayAmount();

        uint256 maxRepay = (debt * closeFactorBps) / DataTypes.BPS;
        if (maxRepay == 0) maxRepay = debt;

        repaid = repayAmount > maxRepay ? maxRepay : repayAmount;
        if (repaid == 0) revert InvalidRepayAmount();

        repaid = market.repayFor(positionId, msg.sender, repaid);

        uint256 repayFractionBps = (repaid * DataTypes.BPS) / debt;
        (seized0, seized1, seizedLiquidity) =
            vault.seizeForLiquidation(positionId, msg.sender, repayFractionBps, liquidationBonusBps);

        if (seized0 < minSeized0 || seized1 < minSeized1) revert InvalidRepayAmount();

        bool forgiven;
        if (!riskManager.isHealthy(positionId)) {
            DataTypes.Position memory p = vault.position(positionId);
            if (p.collateral0 == 0 && p.collateral1 == 0 && p.leveragedLiquidity == 0) {
                market.forgiveBadDebt(positionId);
                forgiven = true;
            }
        }

        emit PositionLiquidated(positionId, msg.sender, repaid, seized0, seized1, seizedLiquidity, forgiven);
    }
}
