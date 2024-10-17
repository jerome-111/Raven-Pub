// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPubVault {
    enum OP {
        Lend,
        Withdraw
    }

    function post_init(address raven_) external;
    function holdLocked(uint256 borrow) external;
    function releaseLocked(uint256 release) external;
    function withdrawLocked() external;
    function deposit(uint256 assets) external returns(uint256 shares);
    function withdraw(uint256 assets) external returns (uint256 shares);
    function redeem(uint256 shares) external returns (uint256 assets);

    /// view
    function safeCheck(uint256 assets, OP op) external view returns(bool);
    function totalLocked() external view returns (uint256);
    function totalMargin() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}