// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DataTypes} from "../libraries/DataTypes.sol";
import {IBorrowingMarket} from "../interfaces/IBorrowingMarket.sol";

contract BorrowingMarket is IBorrowingMarket, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SECONDS_PER_YEAR = 365 days;

    struct RateConfig {
        uint16 kinkUtilizationBps;
        uint16 reserveFactorBps;
        uint256 baseRatePerYearRay;
        uint256 slope1PerYearRay;
        uint256 slope2PerYearRay;
    }

    error NotBorrower();
    error NotRepayer();
    error NotLiquidationModule();
    error InvalidConfig();
    error InsufficientLiquidity();

    event BorrowerUpdated(address indexed account, bool allowed);
    event RepayerUpdated(address indexed account, bool allowed);
    event LiquidationModuleUpdated(address indexed liquidationModule);
    event RateConfigUpdated(RateConfig config);
    event Supplied(address indexed supplier, address indexed onBehalfOf, uint256 assets, uint256 shares);
    event Withdrawn(address indexed supplier, address indexed receiver, uint256 assets, uint256 shares);
    event Borrowed(uint256 indexed positionId, address indexed receiver, uint256 assets, uint256 scaledDebtAdded);
    event Repaid(uint256 indexed positionId, address indexed payer, uint256 assets, uint256 scaledDebtReduced);
    event InterestAccrued(uint256 previousIndexRay, uint256 newIndexRay, uint256 interestAccrued, uint256 reserveAdded);
    event BadDebtForgiven(uint256 indexed positionId, uint256 debtAmount, uint256 uncoveredLoss);

    IERC20 public immutable token;

    uint256 public totalSupplyShares;
    uint256 public totalScaledDebt;
    uint256 public borrowIndexRay;
    uint256 public lastAccrualTime;
    uint256 public reserveBalance;
    uint256 public badDebt;

    address public liquidationModule;

    mapping(address => uint256) public supplyShares;
    mapping(uint256 => uint256) public scaledDebtOf;
    mapping(address => bool) public isBorrower;
    mapping(address => bool) public isRepayer;

    RateConfig public rateConfig;

    modifier onlyBorrower() {
        if (!isBorrower[msg.sender]) revert NotBorrower();
        _;
    }

    modifier onlyRepayer() {
        if (!isRepayer[msg.sender]) revert NotRepayer();
        _;
    }

    modifier onlyLiquidationModule() {
        if (msg.sender != liquidationModule) revert NotLiquidationModule();
        _;
    }

    modifier accrues() {
        if (block.timestamp >= lastAccrualTime) accrueInterest();
        _;
    }

    constructor(address borrowAsset, address admin) Ownable(admin) {
        token = IERC20(borrowAsset);
        borrowIndexRay = DataTypes.RAY;
        lastAccrualTime = block.timestamp;

        rateConfig = RateConfig({
            kinkUtilizationBps: 8_000,
            reserveFactorBps: 1_000,
            baseRatePerYearRay: 0.04e27,
            slope1PerYearRay: 0.16e27,
            slope2PerYearRay: 1.80e27
        });
    }

    function borrowToken() external view returns (address) {
        return address(token);
    }

    function setBorrower(address account, bool allowed) external onlyOwner {
        isBorrower[account] = allowed;
        emit BorrowerUpdated(account, allowed);
    }

    function setRepayer(address account, bool allowed) external onlyOwner {
        isRepayer[account] = allowed;
        emit RepayerUpdated(account, allowed);
    }

    function setLiquidationModule(address module) external onlyOwner {
        liquidationModule = module;
        emit LiquidationModuleUpdated(module);
    }

    function setRateConfig(RateConfig calldata config) external onlyOwner {
        if (config.kinkUtilizationBps == 0 || config.kinkUtilizationBps >= DataTypes.BPS) revert InvalidConfig();
        if (config.reserveFactorBps > DataTypes.BPS) revert InvalidConfig();
        rateConfig = config;
        emit RateConfigUpdated(config);
    }

    function supply(uint256 assets, address onBehalfOf) external nonReentrant accrues returns (uint256 shares) {
        address beneficiary = onBehalfOf == address(0) ? msg.sender : onBehalfOf;
        uint256 assetsBefore = totalAssets();

        token.safeTransferFrom(msg.sender, address(this), assets);

        if (totalSupplyShares == 0 || assetsBefore == 0) {
            shares = assets;
        } else {
            shares = (assets * totalSupplyShares) / assetsBefore;
        }
        if (shares == 0) revert InvalidConfig();

        totalSupplyShares += shares;
        supplyShares[beneficiary] += shares;

        emit Supplied(msg.sender, beneficiary, assets, shares);
    }

    function withdraw(uint256 shares, address receiver) external nonReentrant accrues returns (uint256 assets) {
        if (shares == 0 || shares > supplyShares[msg.sender]) revert InvalidConfig();

        assets = (shares * totalAssets()) / totalSupplyShares;
        if (assets > token.balanceOf(address(this))) revert InsufficientLiquidity();

        supplyShares[msg.sender] -= shares;
        totalSupplyShares -= shares;

        token.safeTransfer(receiver, assets);

        emit Withdrawn(msg.sender, receiver, assets, shares);
    }

    function borrowFor(uint256 positionId, address receiver, uint256 amount)
        external
        onlyBorrower
        nonReentrant
        accrues
    {
        if (amount > token.balanceOf(address(this))) revert InsufficientLiquidity();

        uint256 scaled = _toScaledUp(amount, borrowIndexRay);
        scaledDebtOf[positionId] += scaled;
        totalScaledDebt += scaled;

        token.safeTransfer(receiver, amount);

        emit Borrowed(positionId, receiver, amount, scaled);
    }

    function repayFor(uint256 positionId, address payer, uint256 amount)
        external
        onlyRepayer
        nonReentrant
        accrues
        returns (uint256 repaid)
    {
        uint256 scaledOutstanding = scaledDebtOf[positionId];
        if (scaledOutstanding == 0 || amount == 0) return 0;

        uint256 debtOutstanding = _toUnderlying(scaledOutstanding, borrowIndexRay);
        repaid = amount > debtOutstanding ? debtOutstanding : amount;

        token.safeTransferFrom(payer, address(this), repaid);

        uint256 scaledReduction;
        if (repaid == debtOutstanding) {
            scaledReduction = scaledOutstanding;
        } else {
            scaledReduction = (repaid * DataTypes.RAY) / borrowIndexRay;
            if (scaledReduction == 0) scaledReduction = 1;
            if (scaledReduction > scaledOutstanding) scaledReduction = scaledOutstanding;
        }

        scaledDebtOf[positionId] = scaledOutstanding - scaledReduction;
        totalScaledDebt -= scaledReduction;

        emit Repaid(positionId, payer, repaid, scaledReduction);
    }

    function forgiveBadDebt(uint256 positionId)
        external
        onlyLiquidationModule
        nonReentrant
        accrues
        returns (uint256 writtenOff)
    {
        uint256 scaledOutstanding = scaledDebtOf[positionId];
        if (scaledOutstanding == 0) return 0;

        writtenOff = _toUnderlying(scaledOutstanding, borrowIndexRay);

        scaledDebtOf[positionId] = 0;
        totalScaledDebt -= scaledOutstanding;

        uint256 uncoveredLoss;
        if (reserveBalance >= writtenOff) {
            reserveBalance -= writtenOff;
        } else {
            uncoveredLoss = writtenOff - reserveBalance;
            reserveBalance = 0;
            badDebt += uncoveredLoss;
        }

        emit BadDebtForgiven(positionId, writtenOff, uncoveredLoss);
    }

    function accrueInterest() public {
        uint256 dt = block.timestamp - lastAccrualTime;
        if (dt == 0) return;

        uint256 oldIndex = borrowIndexRay;

        if (totalScaledDebt == 0) {
            lastAccrualTime = block.timestamp;
            return;
        }

        uint256 debtBefore = _toUnderlying(totalScaledDebt, oldIndex);
        uint256 utilBps = _utilizationBps(debtBefore, token.balanceOf(address(this)));
        uint256 ratePerSecondRay = _borrowRatePerSecondRay(utilBps);

        uint256 linearInterestFactorRay = DataTypes.RAY + ((ratePerSecondRay * dt));
        uint256 newIndex = (oldIndex * linearInterestFactorRay) / DataTypes.RAY;

        borrowIndexRay = newIndex;
        lastAccrualTime = block.timestamp;

        uint256 debtAfter = _toUnderlying(totalScaledDebt, newIndex);
        uint256 accrued = debtAfter > debtBefore ? debtAfter - debtBefore : 0;
        uint256 reserveAdded = (accrued * rateConfig.reserveFactorBps) / DataTypes.BPS;
        reserveBalance += reserveAdded;

        emit InterestAccrued(oldIndex, newIndex, accrued, reserveAdded);
    }

    function debtOf(uint256 positionId) public view returns (uint256) {
        return _toUnderlying(scaledDebtOf[positionId], previewBorrowIndexRay());
    }

    function totalDebt() public view returns (uint256) {
        return _toUnderlying(totalScaledDebt, previewBorrowIndexRay());
    }

    function utilizationBps() external view returns (uint256) {
        uint256 debt = totalDebt();
        return _utilizationBps(debt, token.balanceOf(address(this)));
    }

    function totalAssets() public view returns (uint256) {
        uint256 cash = token.balanceOf(address(this));
        uint256 debt = totalDebt();

        uint256 gross = cash + debt;
        uint256 loss = reserveBalance + badDebt;
        if (loss >= gross) return 0;
        return gross - loss;
    }

    function previewBorrowIndexRay() public view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrualTime;
        if (dt == 0 || totalScaledDebt == 0) return borrowIndexRay;

        uint256 debtBefore = _toUnderlying(totalScaledDebt, borrowIndexRay);
        uint256 utilBps = _utilizationBps(debtBefore, token.balanceOf(address(this)));
        uint256 ratePerSecondRay = _borrowRatePerSecondRay(utilBps);
        uint256 linearInterestFactorRay = DataTypes.RAY + ((ratePerSecondRay * dt));

        return (borrowIndexRay * linearInterestFactorRay) / DataTypes.RAY;
    }

    function previewBorrowRatePerYearRay() external view returns (uint256) {
        uint256 debt = totalDebt();
        uint256 utilBps = _utilizationBps(debt, token.balanceOf(address(this)));
        return _borrowRatePerYearRay(utilBps);
    }

    function _borrowRatePerSecondRay(uint256 utilBps) internal view returns (uint256) {
        return _borrowRatePerYearRay(utilBps) / SECONDS_PER_YEAR;
    }

    function _borrowRatePerYearRay(uint256 utilBps) internal view returns (uint256) {
        RateConfig memory cfg = rateConfig;

        if (utilBps <= cfg.kinkUtilizationBps) {
            return cfg.baseRatePerYearRay + ((cfg.slope1PerYearRay * utilBps) / cfg.kinkUtilizationBps);
        }

        uint256 excessUtil = utilBps - cfg.kinkUtilizationBps;
        uint256 postKinkSpan = DataTypes.BPS - cfg.kinkUtilizationBps;

        return cfg.baseRatePerYearRay + cfg.slope1PerYearRay + ((cfg.slope2PerYearRay * excessUtil) / postKinkSpan);
    }

    function _utilizationBps(uint256 debt, uint256 cash) internal pure returns (uint256) {
        uint256 denom = debt + cash;
        if (denom == 0 || debt == 0) return 0;
        return (debt * DataTypes.BPS) / denom;
    }

    function _toScaledUp(uint256 amount, uint256 indexRay) internal pure returns (uint256) {
        if (amount == 0) return 0;
        return ((amount * DataTypes.RAY) + (indexRay - 1)) / indexRay;
    }

    function _toUnderlying(uint256 scaledAmount, uint256 indexRay) internal pure returns (uint256) {
        if (scaledAmount == 0) return 0;
        return (scaledAmount * indexRay) / DataTypes.RAY;
    }
}
