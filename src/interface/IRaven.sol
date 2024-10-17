// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRaven {
    enum OType{
        CALL,
        PUT
    }

    struct ConstructParams {
        address Admin;                  // 0xe1e9eEdefe039017AbC658FaA23C2Fcb9C833DDF
        address Forwarder;
        address Usdt;                   // 0x8f860AF0c07336Cd0E944ead52a59fFfcF2067CA | sepolia
        address DataFeedAddress;        // 0x694AA1769357215DE4FAC081bf1f309aDC325306 | sepolia ETH/USD
        address PubVaultAddress;
        
        uint256 BaseSharePrice;         // 10 * (10 ** UsdtDecimals);
        uint256 RoundWindow;            // 18 hours | 64800
        uint256 IncenWindow;            // 3 hours | incentive VToken window hours 
        uint256 Expiration;             // 24 hours | 86400
        uint256 TimeFactor;             // 15 minutes | 900
        uint256 PriceFactor;            // 15
        uint256 StrikeSpacing;          // 25
        uint256 MaxLeverage;            // 100

        uint256 BasePerc;               // 100
        uint256 WinPerc;                // 50
        uint256 WinnerPerc;             // 99
        uint256 AdminPerc;              // 1
        uint256 LqdtAdminFeePerc;       // 5
        uint256 LqdtVaultFeePerc;       // 45
        uint256 IncenVTokenPerc;        // 200
        uint256 LiquidationVTokenPerc;  // 200 

        uint8 UsdtDecimals;             // 6
        uint8 VSlots;                   // 5
    }

    struct SpotPosition {
        uint256 Share;
        uint256 Value;
    }

    struct LevgPosition {
        uint256 Share;
        uint256 Value;
        uint256 Margin;
        uint256 Leverage;
        uint256 OpenTime;
    }

    struct AddPositionParams {
        bytes32 OptionId; 
        uint256 ShareToAdd; 
        uint256 ValueToAdd;
        uint256 MarginToAdd;
        uint256 Leverage; 
        address User;
        bool IsLqdt;
    }

    struct Redeem {
        OType Otype;
        bytes32 OId;
        uint256 RedeemShare;
        uint256 RedeemValue;
    }

    struct LqdtInfo {
        uint256 DeductTotalValue;
        uint256 ReturnBorrowedMargin;
        uint256 LiquidatedMargin;
        uint256 AdminFee;
        uint256 VaultFee;
    }

    /// admin func
    function strike() external;
    function updateForwarder(address newForwarder) external;
    function updateParams(ConstructParams memory cp) external;
    function enableLevg(bool enabled) external;

    /// user func
    function openPositionSpot(OType oType, uint8 slot, uint256 shares) external;
    function openPositionLevg(OType oType, uint8 slot, uint256 shares, uint256 leverage) external;
    function redeemSpotBatch(uint256 redeemRound, OType[] memory oTypes, uint8[] memory slots) external;
    function redeemLevgBatch(uint256 redeemRound, OType[] memory oTypes, uint8[] memory slots) external;
    function addMargin(OType oType, uint8 slot, uint256 marginToAdd) external;
    function liquidationCall(OType oType, uint8 slot, address user, uint256 callShare) external;

    event LiquidationUpdated(address user, OType oType, uint8 slot, uint256 lvgValue, uint256 newShare, uint256 newMargin, uint256 openTime, uint256 updateBlock);
}