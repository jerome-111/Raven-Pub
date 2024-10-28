// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";
import {IPubVault} from "./interface/IPubVault.sol";

import {Test, console} from "forge-std/Test.sol";

contract PubVault is OwnableUpgradeable, ERC20Upgradeable, UUPSUpgradeable, IPubVault {
    using Math for uint256; 
    address public raven;
    address public usdt;
    uint256 public minDeposit;
    uint256 public maxDeposit;
    uint256 public basePerc; /// 100
    uint256 public safeLine; /// totalLockedAsset / totalAsset >= safeLine / basePerc

    uint256 public totalLockedAsset;
    uint256 public totalDeposits;
    uint256 public totalWithdraws;
    mapping(address user => uint256 deposits) public userDeposits;
    mapping(address user => uint256 withdraws) public userWithdraws;

    modifier onlyRaven() {
        require(msg.sender == raven, 'only Raven');
        _;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function initialize(
        address owner_, 
        address raven_, 
        address usdt_, 
        uint256 minDeposit_,
        uint256 maxDeposit_,
        uint256 safeLine_
    ) public initializer {
        require(usdt_ != address(0), "invalid usdt address(0)");
        require(minDeposit_ > 0, "invalid minDeposit: 0");
        require(maxDeposit_ > 0, "invalid maxDeposit: 0");
        require(minDeposit_ < maxDeposit_, "minDeposit < maxDeposit");
        __Ownable_init(owner_);
        __ERC20_init("Raven Pool Share", "RPS");
        __UUPSUpgradeable_init();
        raven = raven_;
        usdt = usdt_;
        minDeposit = minDeposit_;
        maxDeposit = maxDeposit_;
        basePerc = 100;
        safeLine = safeLine_;
    }

    function post_init(address raven_) external onlyOwner {
        require(raven_ != address(0), "invalid raven address(0)");
        raven = raven_;
    }

    /// only Raven
    function safeCheck(uint256 assets, OP op) external view returns(bool) {
        return _safeCheck(assets, op);
    }

    function holdLocked(uint256 borrow) external onlyRaven {
        totalLockedAsset += borrow;
    }

    function releaseLocked(uint256 release) external onlyRaven {
        totalLockedAsset = totalLockedAsset >= release ? totalLockedAsset - release : 0;
    }

    function withdrawLocked() external onlyRaven {
        uint256 amountWithdraw = totalLockedAsset;
        totalLockedAsset = 0;
        TransferHelper.safeTransfer(usdt, raven, amountWithdraw);
    }

    /// user func
    function deposit(uint256 assets) external returns(uint256 shares) {
        require(assets >= minDeposit && assets <= maxDeposit, "invalid deposits");
        shares = _previewDeposit(assets);
        totalDeposits += assets;
        userDeposits[msg.sender] += assets;
        TransferHelper.safeTransferFrom(usdt, msg.sender, address(this), assets);
        _mint(msg.sender, shares);
    }

    function withdraw(uint256 assets) external returns (uint256 shares) {
        require(assets <= _maxWithdraw(msg.sender), "exceed max assets");
        require(_safeCheck(assets, OP.Withdraw), "safe check not pass");
        shares = _previewWithdraw(assets);
        totalWithdraws += assets;
        userWithdraws[msg.sender] += assets;
        _burn(msg.sender, shares);
        TransferHelper.safeTransfer(usdt, msg.sender, assets);
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        require(shares <= _maxRedeem(msg.sender), "exceed max redeems");
        assets = _previewRedeem(shares);
        require(_safeCheck(assets, OP.Withdraw), "safe check not pass");
        totalWithdraws += assets;
        userWithdraws[msg.sender] += assets;
        _burn(msg.sender, shares);
        TransferHelper.safeTransfer(usdt, msg.sender, assets);
    }

    /// owner func
    function updateSafeLine(uint256 newSafeLine) external onlyOwner {
        safeLine = newSafeLine;
    }

    function updateMaxDeposit(uint256 newMaxDeposit) external onlyOwner {
        require(newMaxDeposit > 0 && newMaxDeposit > minDeposit, "invalid newMaxDeposit");
        maxDeposit = newMaxDeposit;
    }

    function updateMinDeposit(uint256 newMinDeposit) external onlyOwner {
        require(newMinDeposit > 0 && newMinDeposit < maxDeposit, "invalid newMaxDeposit");
        minDeposit = newMinDeposit;
    }

    /// EIP4626 utils
    function totalLocked() external view returns (uint256) {
        return totalLockedAsset;
    }

    function totalMargin() external view returns (uint256) {
        return _totalAssets() * safeLine / basePerc - totalLockedAsset;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets();
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return _maxWithdraw(owner);
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return _maxRedeem(owner);
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return _previewDeposit(assets);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return _previewWithdraw(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return _previewRedeem(shares);
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// internal func
    function _totalAssets() internal view returns (uint256) {
        return IERC20(usdt).balanceOf(address(this));
    }

    function _maxWithdraw(address owner) internal view returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }

    function _maxRedeem(address owner) internal view returns (uint256) {
        return balanceOf(owner);
    }

    function _previewDeposit(uint256 assets) internal view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function _previewWithdraw(uint256 assets) internal view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function _previewRedeem(uint256 shares) internal view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), _totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        return shares.mulDiv(_totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    function _safeCheck(uint256 assets, OP op) internal view returns(bool) {
        if(op == OP.Lend) { return (assets + totalLockedAsset) * basePerc <= _totalAssets() * safeLine; }
        else if(op == OP.Withdraw) { return totalLockedAsset * basePerc <= (_totalAssets() - assets) * safeLine; }
        else return false;
    }

    // https://docs.openzeppelin.com/contracts/5.x/erc4626
    function _decimalsOffset() internal view virtual returns (uint8) {
        return 0;
    }
}
