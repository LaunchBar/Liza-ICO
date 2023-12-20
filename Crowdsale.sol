// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Crowdsale
/// @notice Crowdsale contract to spend project tokens
contract Crowdsale is ReentrancyGuard, Ownable {
    using SafeERC20 for ERC20;

    uint256 public constant MIN_LZC_AMOUNT = 5 * 1e18;
    uint256 public constant MAX_LZC_AMOUNT = 5000 * 1e18;

    //the address to which user funds are received
    address public immutable recepient;

    ERC20 public immutable token;
    ERC20 public immutable usdt;
    ERC20 public immutable usdc;
    ERC20 public immutable busd;

    AggregatorV3Interface public priceOracleBNBUSDT;

    //current price of token
    uint256 public currentPriceInUsd;

    enum Asset {
        USDT,
        USDC,
        BUSD,
        BNB
    }

    //balance of LZC for claim
    mapping(address => uint256) public balances;

    uint256 public soldCount;
    uint256 public amountToSale;

    bool public isFinished;

    event IcoStarted();
    event IcoFinished();

    constructor(
        address _token,
        address _usdt,
        address _usdc,
        address _busd,
        address _priceOracleBNBUSDT,
        address _recepient
    ) {
        usdt = ERC20(_usdt);
        usdc = ERC20(_usdc);
        busd = ERC20(_busd);
        token = ERC20(_token);
        priceOracleBNBUSDT = AggregatorV3Interface(_priceOracleBNBUSDT);
        recepient = _recepient;
    }

    ///crowdsale initialization
    function init(uint256 tokensCount, uint256 priceInUsd) external onlyOwner {
        currentPriceInUsd = priceInUsd;
        amountToSale = tokensCount;
        emit IcoStarted();
    }

    //returns token price in BNB
    function getLzcPriceInBnb() public view returns (uint256) {
        (, int256 bnbPriceInUsd, , , ) = priceOracleBNBUSDT.latestRoundData(); // Price in BNB from Oracle
        uint256 bnbPrice = uint256(bnbPriceInUsd);
        uint256 decimals = 8; // Decimals in BNB price

        //calc LZC in BNB price
        uint256 lzcPriceInUsd = currentPriceInUsd; // current price of one LZC in USD
        uint256 lzcPriceInBnb = (lzcPriceInUsd * (10 ** decimals)) / bnbPrice;

        return lzcPriceInBnb;
    }

    //returns lzc count for asset amount
    function getLzcAmount(
        uint256 value,
        Asset asset
    ) public view returns (uint256) {
        if (asset == Asset.BNB) {
            (, int256 answer, , , ) = priceOracleBNBUSDT.latestRoundData(); //BNB in USD price
            uint256 bnbPrice = uint256(answer);
            uint256 decimals = 8; // Decimals in BNB price
            uint256 usdAmountInBnbValue = (value * bnbPrice) / (10 ** decimals);
            value = usdAmountInBnbValue;
        }
        return (value / currentPriceInUsd) * 10 ** token.decimals();
    }

    //пget token
    function getUsd(Asset asset) private view returns (ERC20) {
        if (asset == Asset.USDT) {
            return usdt;
        }
        if (asset == Asset.USDC) {
            return usdc;
        }
        return busd;
    }

    /// @notice Buy token for USDT
    /// @param value assets amount
    /// @param asset asset to buy token
    function buy(uint256 value, Asset asset) external payable nonReentrant {
        uint256 lzcAmount = getLzcAmount(
            asset == Asset.BNB ? msg.value : value,
            asset
        );
        require(lzcAmount > 0, "Insufficient funds");
        require(lzcAmount >= MIN_LZC_AMOUNT, "MIN 5 LZC");
        require(lzcAmount <= MAX_LZC_AMOUNT, "MAX 5000 LZC");
        require(!isFinished, "ICO Finished");

        // calculation of spended amount
        uint256 spentAmount;
        if (asset == Asset.BNB) {
            spentAmount = (lzcAmount * getLzcPriceInBnb()) / (10 ** 18);
            uint256 refund = msg.value - spentAmount;
            if (refund > 0) {
                payable(msg.sender).transfer(refund);
            }
            payable(recepient).transfer(msg.value - refund);
        } else {
            getUsd(asset).safeTransferFrom(msg.sender, address(this), value);
            spentAmount = (lzcAmount * currentPriceInUsd) / (10 ** 18);
            uint256 refund = value - spentAmount;
            if (refund > 0) {
                getUsd(asset).transfer(msg.sender, refund);
            }
            getUsd(asset).transfer(recepient, value - refund);
        }

        balances[msg.sender] += lzcAmount;
        soldCount += lzcAmount;

        //we check if there is less than the minimum left on the contract, then we complete the crowdsale by sending all tokens to the recipient
        if (amountToSale - soldCount < MIN_LZC_AMOUNT) {
            isFinished = true;
            token.transfer(recepient, amountToSale - soldCount);
            soldCount = amountToSale;
            emit IcoFinished();
        }
    }

    //if the crowdsale is over, it withdraws the user’s tokens to his wallet
    function claim() external {
        require(isFinished, "ICO is not finished");
        uint256 balance = balances[msg.sender];
        balances[msg.sender] = 0;
        token.transfer(msg.sender, balance);
    }
}
