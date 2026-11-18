// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
    OPHIR
    The legendary gold of King Solomon. Build your house, fill your storage and wake the generator to earn $OPHR.
    https://ophirbnb.pages.dev

    Plain fixed-supply ERC-20 on BNB Smart Chain.
    - 1,000,000,000 OPHR minted once in the constructor, no mint function afterwards.
    - No owner, no admin, no pause, no blacklist, no tax, no transfer limits, no transfer hooks, no proxy.
    - Project links are set once in the constructor and can never be changed.
*/

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract OphirToken is ERC20, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant LIQUIDITY_ALLOCATION = 500_000_000 ether;
    uint256 public constant MINING_ALLOCATION = 400_000_000 ether;
    uint256 public constant PARTNER_ALLOCATION = 100_000_000 ether;

    error ZeroAddress();

    // Written once in the constructor; there is no setter.
    string private _website;
    string private _x;
    string private _description;
    string private _logoURI;

    constructor(
        address liquidityWallet,
        address miningPool,
        address partnerWallet,
        string memory website_,
        string memory x_,
        string memory description_,
        string memory logoURI_
    ) ERC20("OPHIR", "OPHR") ERC20Permit("OPHIR") {
        if (liquidityWallet == address(0) || miningPool == address(0) || partnerWallet == address(0)) {
            revert ZeroAddress();
        }
        _website = website_;
        _x = x_;
        _description = description_;
        _logoURI = logoURI_;
        _mint(liquidityWallet, LIQUIDITY_ALLOCATION);
        _mint(miningPool, MINING_ALLOCATION);
        _mint(partnerWallet, PARTNER_ALLOCATION);
    }

    function website() external view returns (string memory) {
        return _website;
    }

    function x() external view returns (string memory) {
        return _x;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function logoURI() external view returns (string memory) {
        return _logoURI;
    }
}
