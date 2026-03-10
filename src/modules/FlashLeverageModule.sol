// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DataTypes} from "../libraries/DataTypes.sol";
import {ILPVault} from "../interfaces/ILPVault.sol";
import {IBorrowingMarket} from "../interfaces/IBorrowingMarket.sol";
import {ILeverageLiquidityHook} from "../interfaces/ILeverageLiquidityHook.sol";
import {IFlashLoanProvider, IFlashLoanBorrower} from "../interfaces/IFlashLoanProvider.sol";
import {RiskManager} from "../RiskManager.sol";

contract FlashLeverageModule is Ownable2Step, ReentrancyGuard, IFlashLoanBorrower {
    using SafeERC20 for IERC20;

    error NotFlashProvider();
    error NotPositionOwner();
    error InvalidBorrowAsset();
    error TickBoundExceeded();
    error HealthFactorTooLow();
    error MaxFlashExceeded();

    bytes32 public constant CALLBACK_SUCCESS = keccak256("IFlashLoanBorrower.onFlashLoan");

    struct FlashLeverageData {
        uint256 positionId;
        address owner;
        uint128 addLiquidity;
        uint256 minHealthFactorWad;
        uint24 maxTickDistance;
    }

    ILPVault public immutable vault;
    IBorrowingMarket public immutable market;
    RiskManager public immutable riskManager;
    ILeverageLiquidityHook public immutable hook;
    IFlashLoanProvider public immutable flashProvider;
    address public immutable borrowAsset;

    uint256 public maxFlashAmount;

    event MaxFlashAmountUpdated(uint256 amount);
    event FlashLeveraged(
        uint256 indexed positionId,
        address indexed owner,
        uint256 flashAmount,
        uint256 fee,
        uint128 addLiquidity,
        uint256 resultingDebt,
        uint256 healthFactorWad
    );

    constructor(
        address admin,
        ILPVault vault_,
        IBorrowingMarket market_,
        RiskManager riskManager_,
        ILeverageLiquidityHook hook_,
        IFlashLoanProvider flashProvider_,
        uint256 maxFlashAmount_
    ) Ownable(admin) {
        vault = vault_;
        market = market_;
        riskManager = riskManager_;
        hook = hook_;
        flashProvider = flashProvider_;
        borrowAsset = market_.borrowToken();
        maxFlashAmount = maxFlashAmount_;
    }

    function setMaxFlashAmount(uint256 amount) external onlyOwner {
        maxFlashAmount = amount;
        emit MaxFlashAmountUpdated(amount);
    }

    function flashLeverage(
        uint256 positionId,
        uint256 flashAmount,
        uint128 addLiquidity,
        uint256 minHealthFactorWad,
        uint24 maxTickDistance
    ) external nonReentrant {
        if (flashAmount == 0 || flashAmount > maxFlashAmount) revert MaxFlashExceeded();

        DataTypes.Position memory p = vault.position(positionId);
        if (p.owner != msg.sender) revert NotPositionOwner();

        bytes memory data = abi.encode(
            FlashLeverageData({
                positionId: positionId,
                owner: msg.sender,
                addLiquidity: addLiquidity,
                minHealthFactorWad: minHealthFactorWad,
                maxTickDistance: maxTickDistance
            })
        );

        flashProvider.flashLoan(this, borrowAsset, flashAmount, data);
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        if (msg.sender != address(flashProvider)) revert NotFlashProvider();

        FlashLeverageData memory f = abi.decode(data, (FlashLeverageData));
        DataTypes.Position memory p = vault.position(f.positionId);
        if (p.owner != f.owner) revert NotPositionOwner();

        DataTypes.PoolMetrics memory m = hook.getPoolMetrics(p.poolId);
        int24 center = int24((int256(p.tickLower) + int256(p.tickUpper)) / 2);
        uint24 distance = _absTickDiff(m.currentTick, center);
        if (distance > f.maxTickDistance) revert TickBoundExceeded();

        IERC20(token).safeTransfer(address(vault), amount);

        if (token == p.token0) {
            vault.increaseLeverage(f.positionId, amount, 0, f.addLiquidity);
        } else if (token == p.token1) {
            vault.increaseLeverage(f.positionId, 0, amount, f.addLiquidity);
        } else {
            revert InvalidBorrowAsset();
        }

        uint256 borrowToRepayFlash = amount + fee;
        market.borrowFor(f.positionId, address(this), borrowToRepayFlash);

        uint256 hf = riskManager.healthFactorWad(f.positionId);
        if (hf < f.minHealthFactorWad) revert HealthFactorTooLow();

        IERC20(token).safeTransfer(address(flashProvider), borrowToRepayFlash);

        emit FlashLeveraged(
            f.positionId,
            f.owner,
            amount,
            fee,
            f.addLiquidity,
            market.debtOf(f.positionId),
            hf
        );

        return CALLBACK_SUCCESS;
    }

    function _absTickDiff(int24 a, int24 b) internal pure returns (uint24) {
        int256 diff = int256(a) - int256(b);
        if (diff < 0) diff = -diff;
        return uint24(uint256(diff));
    }
}
