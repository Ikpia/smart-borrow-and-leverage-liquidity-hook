// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IBorrowingMarket {
    function borrowToken() external view returns (address);
    function debtOf(uint256 positionId) external view returns (uint256);

    function borrowFor(uint256 positionId, address to, uint256 amount) external;

    function repayFor(uint256 positionId, address payer, uint256 amount) external returns (uint256 repaid);

    function forgiveBadDebt(uint256 positionId) external returns (uint256 writtenOff);
}
