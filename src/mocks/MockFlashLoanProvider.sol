// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFlashLoanProvider, IFlashLoanBorrower} from "../interfaces/IFlashLoanProvider.sol";
import {DataTypes} from "../libraries/DataTypes.sol";

contract MockFlashLoanProvider is IFlashLoanProvider, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error FlashLoanNotRepaid();
    error CallbackFailed();

    bytes32 public constant CALLBACK_SUCCESS = keccak256("IFlashLoanBorrower.onFlashLoan");

    uint256 public feeBps = 8;

    event FeeUpdated(uint256 feeBps);
    event FlashLoanExecuted(address indexed receiver, address indexed token, uint256 amount, uint256 fee);

    constructor(address admin) Ownable(admin) {}

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > 500) revert CallbackFailed();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function flashLoan(IFlashLoanBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        nonReentrant
    {
        IERC20 asset = IERC20(token);

        uint256 balBefore = asset.balanceOf(address(this));
        uint256 fee = (amount * feeBps) / DataTypes.BPS;

        asset.safeTransfer(address(receiver), amount);

        bytes32 response = receiver.onFlashLoan(msg.sender, token, amount, fee, data);
        if (response != CALLBACK_SUCCESS) revert CallbackFailed();

        uint256 balAfter = asset.balanceOf(address(this));
        if (balAfter < balBefore + fee) revert FlashLoanNotRepaid();

        emit FlashLoanExecuted(address(receiver), token, amount, fee);
    }
}
