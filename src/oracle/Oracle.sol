// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../interface/uniswapV3/IUniswapV3Pool.sol";
import "../lib/uniswapV3/TickMath.sol";
import "../lib/uniswapV3/FixedPoint96.sol";
import "../lib/uniswapV3/FullMath.sol";

interface IOracle {
    function updateTwapInterval(uint32 newTwapInterval) external;
    function getSqrtTwapX96() external view returns (uint160 sqrtPriceX96);
    function getPriceX96FromSqrtPriceX96(uint160 sqrtPriceX96) external pure returns(uint256 priceX96);
    function getPrice() external view returns (uint256);
    function getPrice(int56 tickCumulatives0, int56 tickCumulatives1) external view returns(uint256);
}

contract Oracle is IOracle, Ownable {
    /**
    Mainnet: 
        POOL: 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36
        WETH: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 | token0 | 18
        USDT: 0xdAC17F958D2ee523a2206206994597C13D831ec7 | token1 | 6
        FEE:  3000
     */
    address public uniswapV3Pool;
    uint32 public twapInterval;

    constructor(address uniswapV3Pool_, uint32 twapInterval_, address owner_) Ownable(owner_) {
        require(uniswapV3Pool_ != address(0), "uniswapV3Pool is zero");
        require(twapInterval_ != 0, "twapInterval is zero");
        uniswapV3Pool = uniswapV3Pool_;
        twapInterval = twapInterval_;
    }

    function updateTwapInterval(uint32 newTwapInterval) external onlyOwner {
        twapInterval = newTwapInterval;
    }

    function _getSqrtTwapX96() internal view returns (uint160 sqrtPriceX96) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval; // from (before)
        secondsAgos[1] = 0; // to (now)

        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(uniswapV3Pool).observe(secondsAgos);

        // tick(imprecise as it's an integer) to price
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
            int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(twapInterval)))
        );
    }

    function _getPriceX96FromSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns(uint256 priceX96) {
        return FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
    }

    function getSqrtTwapX96() external view returns (uint160 sqrtPriceX96) {
        return _getSqrtTwapX96();
    }

    function getPriceX96FromSqrtPriceX96(uint160 sqrtPriceX96) external pure returns(uint256 priceX96) {
        return _getPriceX96FromSqrtPriceX96(sqrtPriceX96);
    }

    function getPrice() external view returns (uint256) {
        uint160 sqrtPriceX96 = _getSqrtTwapX96();
        uint256 priceX96 = _getPriceX96FromSqrtPriceX96(sqrtPriceX96);
        uint256 price = FullMath.mulDiv(priceX96, 10**18, FixedPoint96.Q96);
        // return price / (10**6);
        // compensation for Chainlink oracle which decimal of USDT is 8
        return price * 100;
    }

    /// test & verify
    function getPrice(int56 tickCumulatives0, int56 tickCumulatives1) external view returns(uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(
            int24((tickCumulatives1 - tickCumulatives0) / int56(uint56(twapInterval)))
        );
        uint256 priceX96 = _getPriceX96FromSqrtPriceX96(sqrtPriceX96);
        uint256 price = FullMath.mulDiv(priceX96, 10**18, FixedPoint96.Q96);
        // return price / (10**6);
        // compensation for Chainlink oracle which decimal of USDT is 8
        return price * 100;
    }
}