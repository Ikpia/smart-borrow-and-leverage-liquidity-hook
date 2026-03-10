// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFlashLoanBorrower {
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32);
}

interface IFlashLoanProvider {
    function flashLoan(IFlashLoanBorrower receiver, address token, uint256 amount, bytes calldata data) external;
    function feeBps() external view returns (uint256);
}
