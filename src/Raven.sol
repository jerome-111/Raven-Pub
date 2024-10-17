// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AggregatorV3Interface} from "foundry-chainlink-toolkit/src/interfaces/feeds/AggregatorV3Interface.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";
import {IRaven} from "./interface/IRaven.sol";
import {IPubVault} from "./interface/IPubVault.sol";

contract Raven is OwnableUpgradeable, ERC20Upgradeable, UUPSUpgradeable, IRaven {
    address public admin;
    address public forwarder; // chainlink upkeep address
    address public usdt;
    
    uint256 public baseSharePrice;
    uint256 public roundWindow;
    uint256 public incenWindow;
    uint256 public expiration;
    uint256 public timeFactor;
    uint256 public priceFactor;
    uint256 public strikeSpacing;
    uint256 public maxLeverage;

    uint256 public basePerc;
    uint256 public winPerc;
    uint256 public winnerPerc;
    uint256 public adminPerc;
    uint256 public lqdtAdminFeePerc;
    uint256 public lqdtVaultFeePerc;
    uint256 public incenVTokenPerc;
    uint256 public liquidationVTokenPerc;
    
    /// ====== Vars ======
    uint256 public globalRound;
    uint256 public lastStrikeTime;
    uint256 public lastStrikeBlock;
    /// ====== Vars ======

    uint8 public usdtDecimals;
    uint8 public vSlots;
    bool public isLevgEnabled;

    IPubVault public pubVault;
    AggregatorV3Interface internal dataFeed;
    
    mapping(bytes32 positionId => SpotPosition sptInfo) public spotPositions;
    mapping(bytes32 positionId => LevgPosition lvgInfo) public levgPositions;
    mapping(bytes32 optionId => uint256 share) public allShare;
    mapping(bytes32 optionId => uint256 value) public allValue;
    mapping(uint256 round => mapping(uint8 slot => uint256 strike)) public strikes;
    mapping(uint256 round => uint256 ethPrice) public ethPrices;

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function initialize(address owner_, string memory name_, string memory symbol_, ConstructParams memory cp) public initializer  {
        __Ownable_init(owner_);
        __ERC20_init(name_, symbol_);
        __UUPSUpgradeable_init();

        admin = cp.Admin;
        forwarder = cp.Forwarder;
        usdt = cp.Usdt;

        baseSharePrice = cp.BaseSharePrice;
        roundWindow = cp.RoundWindow;
        incenWindow = cp.IncenWindow;
        expiration = cp.Expiration;
        timeFactor = cp.TimeFactor;
        priceFactor = cp.PriceFactor;
        strikeSpacing = cp.StrikeSpacing;
        maxLeverage = cp.MaxLeverage;
        
        basePerc = cp.BasePerc;
        winPerc = cp.WinPerc;
        winnerPerc = cp.WinnerPerc;
        adminPerc = cp.AdminPerc;
        lqdtAdminFeePerc = cp.LqdtAdminFeePerc;
        lqdtVaultFeePerc = cp.LqdtVaultFeePerc;
        incenVTokenPerc = cp.IncenVTokenPerc;
        liquidationVTokenPerc = cp.LiquidationVTokenPerc;

        usdtDecimals = cp.UsdtDecimals;
        vSlots = cp.VSlots; // total slots
        
        /*** Chainlink Data Feed
            * Network: Arbitrum
            * Aggregator: ETH/USD
            * Address: 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612

            * Network: Sepolia
            * Aggregator: ETH/USD
            * Address: 0x694AA1769357215DE4FAC081bf1f309aDC325306
        */
        dataFeed = AggregatorV3Interface(cp.DataFeedAddress);
        pubVault = IPubVault(cp.PubVaultAddress);
    }
 
    /// User Func
    function openPositionSpot(OType oType, uint8 slot, uint256 shares) external {
        require(shares > 0, "invalid share num");
        require(block.timestamp - lastStrikeTime <= roundWindow, "open position window closed");
        bytes32 oId = _optionId(globalRound, slot, oType);
        (uint256 newSharePrice, ) = _sharePrice(oType, slot); 
        uint256 inputValue = shares * newSharePrice;
        AddPositionParams memory app = AddPositionParams({
            OptionId: oId,
            ShareToAdd: shares,
            ValueToAdd: inputValue,
            MarginToAdd: 0,
            Leverage: 1,
            User: msg.sender,
            IsLqdt: false
        });
        _addPosition(app);
        TransferHelper.safeTransferFrom(usdt, msg.sender, address(this), inputValue);
    }

    function openPositionLevg(OType oType, uint8 slot, uint256 shares, uint256 leverage) external {
        require(isLevgEnabled, "Levg Not enabled");
        bytes32 oId = _optionId(globalRound, slot, oType);
        bytes32 pId = _positionId(oId, msg.sender);
        require(_verifyLevgPos(shares, leverage), "verify failed");
        (uint256 newSharePrice, bool isLqdt) = _sharePrice(oType, slot); 
        uint256 valueToAdd = shares * newSharePrice;
        uint256 marginToAdd = valueToAdd / leverage + 1;
        uint256 borrowed = valueToAdd - marginToAdd;
        require(pubVault.safeCheck(borrowed, IPubVault.OP.Lend), "not enough margin");
        pubVault.holdLocked(borrowed);
        AddPositionParams memory app = AddPositionParams({
            OptionId: oId,
            ShareToAdd: shares,
            ValueToAdd: valueToAdd,
            MarginToAdd: marginToAdd,
            Leverage: leverage,
            User: msg.sender,
            IsLqdt: isLqdt
        });
        _addPosition(app);
        TransferHelper.safeTransferFrom(usdt, msg.sender, address(this), marginToAdd);
        LevgPosition memory curPos = levgPositions[pId];
        emit LiquidationUpdated(msg.sender, oType, slot, curPos.Value, curPos.Share, curPos.Margin, curPos.OpenTime, block.number);
    }

    function _addPosition(AddPositionParams memory app) internal {
        allShare[app.OptionId] += app.ShareToAdd;
        allValue[app.OptionId] += app.ValueToAdd;
        bytes32 pId = _positionId(app.OptionId, app.User);
        if (app.Leverage == 1){
            spotPositions[pId].Share += app.ShareToAdd;
            spotPositions[pId].Value += app.ValueToAdd;
        } else {
            LevgPosition memory oldPos = levgPositions[pId];
            uint256 newValue = oldPos.Value + app.ValueToAdd;
            uint256 newMargin = oldPos.Margin + app.MarginToAdd;
            uint256 newLeverage = oldPos.Leverage == 0 ? app.Leverage : (oldPos.Value + app.ValueToAdd) / (oldPos.Margin + app.MarginToAdd);
            uint256 newOpenTime = oldPos.OpenTime == 0 ? block.timestamp : oldPos.OpenTime;
            if (app.IsLqdt) { require(_liquidationTime(newOpenTime, newValue, newMargin) <= lastStrikeTime + expiration, "Lqdt time exceed expiration"); }
            levgPositions[pId] = LevgPosition({
                Share: oldPos.Share + app.ShareToAdd, 
                Value: newValue, 
                Margin: newMargin, 
                Leverage: newLeverage, 
                OpenTime: newOpenTime
            });
        }
        uint256 sharesToMint = block.timestamp <= lastStrikeTime + incenWindow ? app.ShareToAdd * incenVTokenPerc / basePerc : app.ShareToAdd;
        _mint(app.User, sharesToMint * (10 ** decimals()));
    }

    function _verifyLevgPos(uint256 shares, uint256 leverage) internal view returns(bool) {
        require(shares > 0, "invalid share");
        require(leverage > 1 && leverage <= maxLeverage, "invalid leverage");
        require(block.timestamp - lastStrikeTime <= roundWindow, "window closed");
        return true;
    }

    function redeemSpotBatch(uint256 redeemRound, OType[] memory oTypes, uint8[] memory slots) external {
        require(redeemRound > 0 && redeemRound < globalRound, "invalid redeem round");
        require(oTypes.length == slots.length, "batch length not match");
        uint256 totalRedeemValue = 0;
        address user = msg.sender;
        for(uint8 i = 0; i < slots.length; i++) {
            uint256 redeemValue = _redeemSpot(redeemRound, oTypes[i], slots[i], user);
            totalRedeemValue += redeemValue;
        }
        if (totalRedeemValue > 0) TransferHelper.safeTransfer(usdt, user, totalRedeemValue);
    }

    function _redeemSpot(uint256 r, OType o, uint8 s, address u) internal returns(uint256 redeemValue) {
        (OType win, OType los) = _win_los(r, s, ethPrices[r]);
        bytes32 winOId = _optionId(r, s, win);
        bytes32 losOId = _optionId(r, s, los);
        bytes32 oId = _optionId(r, s, o);
        bytes32 pId = _positionId(oId, u);
        SpotPosition storage sPos = spotPositions[pId];
        redeemValue = _previewSpotRedeemValue(o == win, sPos.Share, sPos.Value, winOId, losOId);
        sPos.Share = 0;
        return redeemValue;
    }

    function _previewSpotRedeemValue(bool isWin, uint256 userShare, uint256 userValue, bytes32 winOId, bytes32 losOId) internal view returns(uint256) {
        if (userShare == 0) return 0;
        return isWin ? userValue + _getReward(userShare, winOId, losOId) : userValue * (basePerc - winPerc) / basePerc;
    }

    function redeemLevgBatch(uint256 redeemRound, OType[] memory oTypes, uint8[] memory slots) external {
        require(redeemRound > 0 && redeemRound < globalRound, "invalid redeem round");
        require(oTypes.length == slots.length, "batch length not match");
        uint256 totalRedeemValue = 0;
        address user = msg.sender;
        for(uint8 i = 0; i < slots.length; i++) {
            uint256 redeemValue = _redeemLevg(redeemRound, oTypes[i], slots[i], user);
            totalRedeemValue += redeemValue;
        }
        if(totalRedeemValue > 0) TransferHelper.safeTransfer(usdt, user, totalRedeemValue);
    }

    function _redeemLevg(uint256 r, OType o, uint8 s, address u) internal returns(uint256 redeemValue) {
        bytes32 oId = _optionId(r, s, o);
        bytes32 pId = _positionId(oId, u);
        LevgPosition storage lPos = levgPositions[pId];
        if (lPos.Value > lPos.Margin) {
            pubVault.releaseLocked(lPos.Value - lPos.Margin);
        }
        (OType win, OType los) = _win_los(r, s, ethPrices[r]);
        if(o == los) {
            lPos.Share = 0;
            return 0;
        }
        bytes32 winOId = _optionId(r, s, win);
        bytes32 losOId = _optionId(r, s, los);
        redeemValue = _previewLevgRedeemValue(lPos.Share, lPos.Margin, winOId, losOId);
        lPos.Share = 0;
        return redeemValue;
    }

    function _previewLevgRedeemValue(uint256 userShare, uint256 userMargin, bytes32 winOId, bytes32 losOId) internal view returns(uint256) {
        if (userShare == 0) return 0;
        return userMargin + _getReward(userShare, winOId, losOId);
    }

    function _getReward(uint256 userWinShare, bytes32 winOptionId, bytes32 losOptionId) internal view returns(uint256) {
        if (allShare[winOptionId] == 0) return 0;
        return allValue[losOptionId] * winPerc * winnerPerc * userWinShare / (basePerc * basePerc * allShare[winOptionId]);
    }

    function addMargin(OType oType, uint8 slot, uint256 marginToAdd) external {
        bytes32 oId = _optionId(globalRound, slot, oType);
        bytes32 pId = _positionId(oId, msg.sender);
        LevgPosition storage lvg = levgPositions[pId];
        require(lvg.Share > 0, "no lvg position");
        (, bool isLqdt) = _sharePrice(oType, slot);
        if (isLqdt) {
            require(_liquidationTime(lvg.OpenTime, lvg.Value, lvg.Margin + marginToAdd) <= lastStrikeTime + expiration, "Lqdt time exceed expiration");
        }
        lvg.Margin += marginToAdd;
        TransferHelper.safeTransferFrom(usdt, msg.sender, address(this), marginToAdd);
        emit LiquidationUpdated(msg.sender, oType, slot, lvg.Value, lvg.Share, lvg.Margin, lvg.OpenTime, block.number);
    }

    function liquidationCall(OType oType, uint8 slot, address user, uint256 callShare) external {
        require(balanceOf(msg.sender) / (10 ** decimals()) >= callShare * liquidationVTokenPerc / basePerc, "not enough vToken balance");
        (bool isLqdt, uint256 margin, uint256 positionShare) = _liquidationInfo(oType, slot, user);
        require(isLqdt, "invalid liquidation call");
        require(callShare <= positionShare, "invalid call share");
        bytes32 oId = _optionId(globalRound, slot, oType);
        bytes32 pId = _positionId(oId, user);
        LevgPosition storage lvg = levgPositions[pId];
        LqdtInfo memory lqdtInfo = _previewLiquidationCall(margin, lvg.Share, lvg.Value, callShare);
        pubVault.releaseLocked(lqdtInfo.ReturnBorrowedMargin);
        lvg.Margin = lvg.Margin >= lqdtInfo.LiquidatedMargin ? lvg.Margin - lqdtInfo.LiquidatedMargin : 0;
        lvg.Share = lvg.Share >= callShare ? lvg.Share - callShare : 0;
        lvg.Value = lvg.Value >= lqdtInfo.DeductTotalValue ? lvg.Value - lqdtInfo.DeductTotalValue : 0;
        allShare[oId] = allShare[oId] >= callShare ? allShare[oId] - callShare : 0;
        allValue[oId] = allValue[oId] >= lqdtInfo.DeductTotalValue ? allValue[oId] - lqdtInfo.DeductTotalValue : 0;
        TransferHelper.safeTransfer(usdt, msg.sender, lqdtInfo.LiquidatedMargin - lqdtInfo.AdminFee - lqdtInfo.VaultFee);
        TransferHelper.safeTransfer(usdt, address(pubVault), lqdtInfo.VaultFee);
        TransferHelper.safeTransfer(usdt, admin, lqdtInfo.AdminFee);
        _burn(msg.sender, callShare * liquidationVTokenPerc / basePerc * (10 ** decimals()));
        emit LiquidationUpdated(user, oType, slot, lvg.Value, lvg.Share, lvg.Margin, lvg.OpenTime, block.number);
    }

    function _liquidationInfo(OType oType, uint8 slot, address user) internal view returns(bool, uint256, uint256) {
        bytes32 pId = _positionId(_optionId(globalRound, slot, oType), user);
        LevgPosition memory lvg = levgPositions[pId];
        if (lvg.Share == 0 || lvg.Value == 0 || lvg.Margin == 0 || lvg.OpenTime == 0) return (false, 0, 0);
        uint256 liquidationTime = _liquidationTime(lvg.OpenTime, lvg.Value, lvg.Margin);
        if (block.timestamp <= liquidationTime) return (false, 0, 0);
        (uint256 ethPriceNow, ) = _getEthPrice();
        uint256 strikePrice = strikes[globalRound][slot];
        if (_ableToLqdt(oType, ethPriceNow, strikePrice)) return (true, lvg.Margin, lvg.Share);
        else return (false, 0, 0);
    }

    function _ableToLqdt(OType oType, uint256 ethPriceNow, uint256 strikePrice) internal pure returns(bool) {
        return ((oType == OType.CALL && ethPriceNow <= strikePrice) || (oType == OType.PUT && ethPriceNow > strikePrice));
    }

    function _previewLiquidationCall(uint256 margin, uint256 positionShare, uint256 positionValue, uint256 callShare) internal view returns(LqdtInfo memory lqdtInfo) {
        uint256 deductTotalValue = positionValue * callShare / positionShare;
        uint256 liquidatedMargin = margin * callShare / positionShare;
        uint256 returnBorrowedMargin = deductTotalValue >= liquidatedMargin ? deductTotalValue - liquidatedMargin : 0;
        uint256 adminFee = liquidatedMargin * lqdtAdminFeePerc / basePerc;
        uint256 vaultFee = liquidatedMargin * lqdtVaultFeePerc / basePerc;
        lqdtInfo = LqdtInfo({
            DeductTotalValue: deductTotalValue,
            ReturnBorrowedMargin: returnBorrowedMargin,
            LiquidatedMargin: liquidatedMargin,
            AdminFee: adminFee,
            VaultFee: vaultFee
        });
    }

    function _liquidationTime(uint256 lvgOpenTime, uint256 lvgValue, uint256 lvgMargin) internal view returns(uint256) {
        return lvgOpenTime + (expiration * lvgMargin / lvgValue);
    }

    /// Admin Func
    function strike() external {
        require(msg.sender == forwarder || msg.sender == admin, "invalid caller");
        (uint256 ethPriceNow, uint8 decimal) = _getEthPrice();
        ethPrices[globalRound] = ethPriceNow;
        lastStrikeTime = block.timestamp;
        lastStrikeBlock = block.number;
        uint256 adminHold = _strike(ethPriceNow);
        globalRound++;
        _setStrikes(ethPriceNow, decimal);
        if (adminHold > 0) TransferHelper.safeTransfer(usdt, admin, adminHold);
    }

    function _strike(uint256 ethPriceNow) internal returns(uint256 adminHold) {
        if (globalRound == 0) return adminHold;
        for(uint8 i = 0; i < vSlots; i++) {
            (, OType los) = _win_los(globalRound, i, ethPriceNow);
            bytes32 losId = _optionId(globalRound, i, los);
            if (pubVault.totalLocked() > 0) {
                pubVault.withdrawLocked();
            }
            adminHold += allValue[losId] * winPerc * adminPerc / (basePerc * basePerc);
        }
    }

    function _setStrikes(uint256 ethPriceNow, uint8 decimal) internal {
        uint256 stdStrike = ((ethPriceNow / (10 ** decimal)) / strikeSpacing) * strikeSpacing - strikeSpacing * ((vSlots - 1) / 2);
        for(uint8 i = 0; i < vSlots; i++) {
            strikes[globalRound][i] = (stdStrike + strikeSpacing * i) * (10 ** decimal);
        }
    }

    function updateForwarder(address newForwarder) external onlyAdmin {
        forwarder = newForwarder;
    }

    function updateParams(ConstructParams memory cp) external onlyAdmin {
        admin = cp.Admin;
        forwarder = cp.Forwarder;
        usdt = cp.Usdt;
        
        baseSharePrice = cp.BaseSharePrice;
        roundWindow = cp.RoundWindow;
        incenWindow = cp.IncenWindow;
        expiration = cp.Expiration;
        timeFactor = cp.TimeFactor;
        priceFactor = cp.PriceFactor;
        strikeSpacing = cp.StrikeSpacing;
        maxLeverage = cp.MaxLeverage;
        
        basePerc = cp.BasePerc;
        winPerc = cp.WinPerc;
        winnerPerc = cp.WinnerPerc;
        adminPerc = cp.AdminPerc;
        lqdtAdminFeePerc = cp.LqdtAdminFeePerc;
        lqdtVaultFeePerc = cp.LqdtVaultFeePerc;
        incenVTokenPerc = cp.IncenVTokenPerc;
        liquidationVTokenPerc = cp.LiquidationVTokenPerc;

        usdtDecimals = cp.UsdtDecimals;
        vSlots = cp.VSlots;
        
        dataFeed = AggregatorV3Interface(cp.DataFeedAddress);
        pubVault = IPubVault(cp.PubVaultAddress);
    }

    function enableLevg(bool enabled) external onlyAdmin {
        isLevgEnabled = enabled;
    }

    /// Utils
    function _getEthPrice() internal view returns(uint256, uint8) {
        /// PROD 
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        return (uint256(answer), dataFeed.decimals());

        // /// Test
        // if (globalRound == 0) return (384835536160, 8);
        // return globalRound % 2 == 0 ? (ethPrices[globalRound - 1] + globalRound * 13, 8) : (ethPrices[globalRound - 1] - globalRound * 17, 8);
    }

    function _win_los(uint256 r, uint8 s, uint256 ethPriceNow) internal view returns(OType win, OType los) {
        (win, los) = ethPriceNow > strikes[r][s] ? (OType.CALL, OType.PUT) : (OType.PUT, OType.CALL);
    }

    function _optionId(uint256 round, uint8 slot, OType oType) internal pure returns(bytes32) {
        return keccak256(abi.encode(round, slot, oType));
    }

    function _positionId(bytes32 oId, address user) internal pure returns(bytes32) {
        return keccak256(abi.encode(oId, user));
    }

    function _sharePrice(OType oType, uint8 slot) internal view returns(uint256 newSharePrice, bool isLqdt) {
        if (lastStrikeTime == 0) return (baseSharePrice, false);
        (uint256 currentEthPrice, uint8 _eth_decimals_) = _getEthPrice();
        uint256 _strike_ = strikes[globalRound][slot];
        uint256 timeBase = expiration / timeFactor;
        uint256 timeExtr = (block.timestamp - lastStrikeTime) / timeFactor + timeBase;
        uint256 _strikeDiff_factor_ = priceFactor * (10 ** _eth_decimals_);
        uint256 priceBase = _strike_ / priceFactor;
        uint256 priceExtr = currentEthPrice / priceFactor;
        uint256 strikeDiff = currentEthPrice > _strike_ ? currentEthPrice - _strike_ : _strike_ - currentEthPrice;
        if (oType == OType.CALL) {
            if (_strike_ < currentEthPrice && strikeDiff >= _strikeDiff_factor_) {
                newSharePrice = baseSharePrice * priceExtr * (timeExtr ** 2) * strikeDiff / (priceBase * (timeBase ** 2) * _strikeDiff_factor_);
            } else if (_strike_ > currentEthPrice && strikeDiff >= _strikeDiff_factor_){
                newSharePrice = baseSharePrice * priceExtr * (timeExtr ** 2) * _strikeDiff_factor_ / (priceBase * (timeBase ** 2) * strikeDiff);
            } else {
                // uint256 demonimator = 2 * (10 ** (_eth_decimals_ - usdtDecimals)); /// _eth_decimals_ = 10, usdtDecimals = 8, hard coded;
                newSharePrice = baseSharePrice * (timeExtr ** 2) / (timeBase ** 2) + currentEthPrice / 200  - _strike_ / 200;
            }
            isLqdt = _strike_ > currentEthPrice;
        } 
        else {
            if (_strike_ > currentEthPrice && strikeDiff >= _strikeDiff_factor_) {
                newSharePrice = baseSharePrice * priceBase * (timeExtr ** 2) * strikeDiff / (priceExtr * (timeBase ** 2) * _strikeDiff_factor_);
            } else if (_strike_ < currentEthPrice && strikeDiff >= _strikeDiff_factor_) {
                newSharePrice = baseSharePrice * priceBase * (timeExtr ** 2) * _strikeDiff_factor_ / (priceExtr * (timeBase ** 2) * strikeDiff);
            } else {
                newSharePrice = baseSharePrice * (timeExtr ** 2) / (timeBase ** 2) + _strike_ / 200  - currentEthPrice / 200 ;
            }
            isLqdt = _strike_ < currentEthPrice;
        }
    }
}