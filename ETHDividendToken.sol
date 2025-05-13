// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title ETHDividendToken
 * @dev A dividend-paying token that distributes ETH to holders proportionally
 * Features:
 * - Automatic ETH distribution to token holders
 * - Claim functionality for users
 * - Excluded addresses (e.g., contracts) from dividends
 * - Gas optimization for distribution
 * - Modern dividend tracking system
 */
contract ETHDividendToken is ERC20, Ownable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant magnitude = 2**128;
    uint256 public minTokenBalanceForDividends = 1000 * (10**18); // Minimum 1000 tokens to receive dividends

    mapping(address => int256) public magnifiedDividendCorrections;
    mapping(address => uint256) public withdrawnDividends;
    mapping(address => bool) public excludedFromDividends;

    uint256 public totalDividendsDistributed;
    uint256 public totalDividendsWithdrawn;
    uint256 public magnifiedDividendPerShare;

    EnumerableSet.AddressSet private tokenHolders;

    event DividendsDistributed(address indexed from, uint256 weiAmount);
    event DividendWithdrawn(address indexed to, uint256 weiAmount);
    event ExcludedFromDividends(address indexed account);
    event IncludedInDividends(address indexed account);
    event MinTokenBalanceUpdated(uint256 newAmount);

    constructor() ERC20("ETH Dividend Token", "ETHDIV") {
        _mint(msg.sender, 100000000 * 10**decimals()); // 100M initial supply
    }

    receive() external payable {
        distributeDividends();
    }

    /**
     * @dev Distributes ETH to token holders as dividends
     */
    function distributeDividends() public payable {
        require(totalSupply() > 0, "No tokens minted yet");

        if (msg.value > 0) {
            magnifiedDividendPerShare = magnifiedDividendPerShare.add(
                (msg.value).mul(magnitude) / totalSupply()
            );
            emit DividendsDistributed(msg.sender, msg.value);
            totalDividendsDistributed = totalDividendsDistributed.add(msg.value);
        }
    }

    /**
     * @dev Withdraws the accumulated dividends for the caller
     */
    function withdrawDividend() public {
        uint256 withdrawableDividend = withdrawableDividendOf(msg.sender);
        require(withdrawableDividend > 0, "No dividends to withdraw");

        withdrawnDividends[msg.sender] = withdrawnDividends[msg.sender].add(withdrawableDividend);
        totalDividendsWithdrawn = totalDividendsWithdrawn.add(withdrawableDividend);
        
        (bool success,) = msg.sender.call{value: withdrawableDividend}("");
        require(success, "ETH transfer failed");
        
        emit DividendWithdrawn(msg.sender, withdrawableDividend);
    }

    /**
     * @dev Calculates the dividend owed to an address
     * @param _owner The address to query
     * @return The amount of ETH the address can withdraw
     */
    function dividendOf(address _owner) public view returns(uint256) {
        return withdrawableDividendOf(_owner);
    }

    /**
     * @dev Returns the withdrawable dividend for an address
     * @param _owner The address to query
     * @return The amount of ETH the address can withdraw
     */
    function withdrawableDividendOf(address _owner) public view returns(uint256) {
        return accumulativeDividendOf(_owner).sub(withdrawnDividends[_owner]);
    }

    /**
     * @dev Returns the total accumulated dividends for an address
     * @param _owner The address to query
     * @return The total accumulated ETH for the address
     */
    function accumulativeDividendOf(address _owner) public view returns(uint256) {
        return magnifiedDividendPerShare.mul(balanceOf(_owner)).toInt256Safe()
            .add(magnifiedDividendCorrections[_owner]).toUint256Safe() / magnitude;
    }

    /**
     * @dev Internal function to transfer tokens and update dividend balances
     */
    function _transfer(address from, address to, uint256 value) internal virtual override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        bool isFromExcluded = excludedFromDividends[from];
        bool isToExcluded = excludedFromDividends[to];

        if (!isFromExcluded) {
            _updateDividendBalance(from);
        }

        if (!isToExcluded) {
            _updateDividendBalance(to);
        }

        super._transfer(from, to, value);

        // Update token holders set
        if (!isFromExcluded && balanceOf(from) == 0) {
            tokenHolders.remove(from);
        }
        if (!isToExcluded && balanceOf(to) >= minTokenBalanceForDividends) {
            tokenHolders.add(to);
        }
    }

    /**
     * @dev Internal function to update dividend balances
     */
    function _updateDividendBalance(address account) internal {
        int256 correction = (magnifiedDividendPerShare.mul(balanceOf(account))).toInt256Safe()
            .sub(magnifiedDividendCorrections[account]);
        
        magnifiedDividendCorrections[account] = (magnifiedDividendPerShare.mul(balanceOf(account))).toInt256Safe();
        
        if (balanceOf(account) >= minTokenBalanceForDividends) {
            tokenHolders.add(account);
        } else {
            tokenHolders.remove(account);
        }
    }

    /**
     * @dev Excludes an address from receiving dividends
     * @param account The address to exclude
     */
    function excludeFromDividends(address account) external onlyOwner {
        require(!excludedFromDividends[account], "Already excluded");
        excludedFromDividends[account] = true;
        
        _updateDividendBalance(account);
        tokenHolders.remove(account);
        
        emit ExcludedFromDividends(account);
    }

    /**
     * @dev Includes an address to receive dividends
     * @param account The address to include
     */
    function includeInDividends(address account) external onlyOwner {
        require(excludedFromDividends[account], "Already included");
        excludedFromDividends[account] = false;
        
        if (balanceOf(account) >= minTokenBalanceForDividends) {
            tokenHolders.add(account);
        }
        
        emit IncludedInDividends(account);
    }

    /**
     * @dev Updates the minimum token balance required to receive dividends
     * @param newAmount The new minimum amount
     */
    function updateMinTokenBalanceForDividends(uint256 newAmount) external onlyOwner {
        require(newAmount != minTokenBalanceForDividends, "Same as current value");
        minTokenBalanceForDividends = newAmount;
        
        // Update all holders' status
        for (uint256 i = 0; i < tokenHolders.length(); i++) {
            address holder = tokenHolders.at(i);
            if (balanceOf(holder) < newAmount) {
                tokenHolders.remove(holder);
            }
        }
        
        emit MinTokenBalanceUpdated(newAmount);
    }

    /**
     * @dev Returns the number of dividend-receiving token holders
     * @return The number of holders
     */
    function getNumberOfTokenHolders() external view returns(uint256) {
        return tokenHolders.length();
    }

    /**
     * @dev Returns the total ETH held by the contract
     * @return The ETH balance
     */
    function getTotalETHHeld() external view returns(uint256) {
        return address(this).balance;
    }
}

// Safe math extensions
library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");
        return c;
    }
}

// Safe casting extensions
library SafeCast {
    function toUint256Safe(int256 a) internal pure returns (uint256) {
        require(a >= 0, "SafeCast: value must be positive");
        return uint256(a);
    }

    function toInt256Safe(uint256 a) internal pure returns (int256) {
        require(a <= uint256(type(int256).max), "SafeCast: value doesn't fit in an int256");
        return int256(a);
    }
}
