// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OphirVault} from "./OphirVault.sol";
import {PxioLpLocker} from "./PxioLpLocker.sol";
import {OphirMiners} from "./OphirMiners.sol";
import {OphirMining} from "./OphirMining.sol";
import {OphirToken} from "./OphirToken.sol";
import {OphirBuildings} from "./OphirBuildings.sol";
import {OphirMarket} from "./OphirMarket.sol";

/*
    OphirDeployer — one-transaction deployment of the whole OPHIR system.

    Deployed via the Arachnid deterministic-deployment proxy (CREATE2). The constructor
    deploys, in order: OphirVault, the LP locker (verbatim), OPHIR Miners, OPHIR Mining,
    the OPHR token, OPHIR Buildings and the OPHIR Market — and performs the full wiring in
    the same order the fork simulation used (mining initialize, market escrow, mint open).

    - The 500,000,000 OPHR liquidity allocation is minted straight into OphirVault.
      NO pool is created and NO liquidity is seeded here: seeding happens later, on the
      owner's order, from the vault through the locker.
    - The LP locker's owner is OphirVault (its mintAndLock is onlyOwner and pulls the
      seeded amounts from its caller, so the vault must be the caller-owner). The locker's
      fee payout wallet is the sdw wallet; fee collection is permissionless.
    - OPHIR Miners is Ownable2Step: the constructor starts the ownership transfer to the
      sdw wallet; it completes when the sdw wallet calls acceptOwnership() once after
      deployment. Every other contract is fully owned by its final owner at construction.
*/
contract OphirDeployer {
    address private constant SDW = 0xE9A232aEfaA230a38BC9Fec961eEA19134903308;
    address private constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address private constant PANCAKE_V3_POSITION_MANAGER = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    string private constant IMAGE_BASE = "https://ophirbnb.pages.dev/art/";

    address public immutable vault;
    address public immutable lpLocker;
    address public immutable token;
    address public immutable miners;
    address public immutable mining;
    address public immutable buildings;
    address public immutable market;

    event Deployed(
        address vault,
        address lpLocker,
        address token,
        address miners,
        address mining,
        address buildings,
        address market
    );

    constructor() {
        OphirVault vault_ = new OphirVault(SDW);
        PxioLpLocker locker_ = new PxioLpLocker(PANCAKE_V3_POSITION_MANAGER, SDW, address(vault_));
        OphirMiners miners_ = new OphirMiners(AGENT_ID_REGISTRY, SDW, SDW, IMAGE_BASE);
        OphirMining mining_ = new OphirMining(address(miners_));
        OphirToken token_ = new OphirToken(
            address(vault_),
            address(mining_),
            SDW,
            "https://ophirbnb.pages.dev",
            "",
            "OPHIR - the legendary gold of King Solomon. Hold OPHIR Miners and earn $OPHR every hour.",
            "https://ophirbnb.pages.dev/art/logo.png"
        );
        OphirBuildings buildings_ = new OphirBuildings(address(token_), SDW);
        mining_.initialize(address(token_), address(buildings_));
        OphirMarket market_ = new OphirMarket(address(miners_), SDW);
        miners_.setEscrow(address(market_));
        miners_.setMintOpen(true);
        miners_.transferOwnership(SDW);

        vault = address(vault_);
        lpLocker = address(locker_);
        token = address(token_);
        miners = address(miners_);
        mining = address(mining_);
        buildings = address(buildings_);
        market = address(market_);
        emit Deployed(vault, lpLocker, token, miners, mining, buildings, market);
    }
}
