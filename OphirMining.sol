// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
    OPHIR Mining (rebuilt from the reference implementation's project documentation plus live
    on-chain probing — see the project AUDIT for exactly what is verified, documented, and inferred).

    Fully on-chain mining. A wallet with at least one revealed OPHIR Miner calls start() once; $OPHR then
    accrues per second at the wallet's boosted tier rate until the Storage cap is reached. claim() pays the
    accrued amount out of this contract's mining allocation and applies the then-current rate and cap:
    changes to miners or buildings only take full effect at the next claim — until then the lower of the
    old and new rate (and cap) applies.
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IOphirMinersView {
    function tiersOf(address o) external view returns (uint256[5] memory counts);
    function miningRate(uint8 t) external pure returns (uint256);
}

interface IOphirBuildingsView {
    function levelsOf(address user) external view returns (uint8 house, uint8 storage_);
}

contract OphirMining is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant TIERS = 5;

    IOphirMinersView public immutable miners;
    IERC20 public pxio;
    IOphirBuildingsView public buildings;
    address private immutable _deployer;

    struct UserInfo {
        bool started;
        uint64 lastTime;
        uint256 rate; // applied rate, OPHR wei per hour (boosted)
        uint256 cap; // applied cap, OPHR wei
        uint256 claimed; // lifetime claimed, OPHR wei
    }

    mapping(address => UserInfo) private _users;

    event Started(address indexed user);
    event Claimed(address indexed user, uint256 amount, uint256 base, uint8 house, uint8 store);

    error NotStarted();
    error AlreadyStarted();
    error AlreadyInitialized();
    error NotDeployer();

    constructor(address miners_) {
        miners = IOphirMinersView(miners_);
        _deployer = msg.sender;
    }

    /// @notice One-time wiring of the token and buildings contracts (deploy order: miners -> mining ->
    ///         token -> buildings -> initialize). Inferred — the original's wiring is not observable.
    function initialize(address pxio_, address buildings_) external {
        if (msg.sender != _deployer) revert NotDeployer();
        if (address(pxio) != address(0)) revert AlreadyInitialized();
        pxio = IERC20(pxio_);
        buildings = IOphirBuildingsView(buildings_);
    }

    // ------------------------------------------------------------------ tables (game data)

    /// @dev Storage capacity in OPHR wei by storage level (1..15). Mirrors the site STORAGE table and the
    ///      OphirBuildings cost table indexing (contract Lv N = site index N-1).
    function storageCap(uint8 level) public pure returns (uint256) {
        if (level == 1) return 150 ether;
        if (level == 2) return 500 ether;
        if (level == 3) return 1200 ether;
        if (level == 4) return 2500 ether;
        if (level == 5) return 4500 ether;
        if (level == 6) return 7500 ether;
        if (level == 7) return 12000 ether;
        if (level == 8) return 18000 ether;
        if (level == 9) return 26000 ether;
        if (level == 10) return 36000 ether;
        if (level == 11) return 50000 ether;
        if (level == 12) return 70000 ether;
        if (level == 13) return 95000 ether;
        if (level == 14) return 130000 ether;
        return 180000 ether; // level 15
    }

    /// @dev House mining boost in basis points by house level (1..10). Mirrors the site HOUSE table.
    function houseBoostBps(uint8 level) public pure returns (uint256) {
        if (level == 1) return 0;
        if (level == 2) return 500;
        if (level == 3) return 1000;
        if (level == 4) return 1500;
        if (level == 5) return 2000;
        if (level == 6) return 2600;
        if (level == 7) return 3200;
        if (level == 8) return 3900;
        if (level == 9) return 4600;
        return 5500; // level 10
    }

    // ------------------------------------------------------------------ views

    /// @notice Unboosted base rate (OPHR wei per hour) from the user's revealed miners, as held now.
    function baseRateOf(address user) public view returns (uint256 base) {
        uint256[5] memory counts = miners.tiersOf(user);
        for (uint8 t; t < TIERS; ++t) {
            if (counts[t] > 0) base += counts[t] * miners.miningRate(t) * 1 ether;
        }
    }

    /// @notice Rate and cap that would apply after the user's next claim, from current miners/buildings.
    function nextOf(address user) public view returns (uint256 nextRate, uint256 nextCap) {
        (uint8 house, uint8 store) = buildings.levelsOf(user);
        nextRate = (baseRateOf(user) * (10_000 + houseBoostBps(house))) / 10_000;
        nextCap = storageCap(store);
    }

    function state(address user)
        external
        view
        returns (
            bool started,
            uint64 lastTime,
            uint256 amount,
            uint256 rate,
            uint256 cap,
            uint256 nextRate,
            uint256 nextCap,
            uint256 claimed
        )
    {
        UserInfo storage u = _users[user];
        started = u.started;
        lastTime = u.lastTime;
        rate = u.rate;
        cap = u.cap;
        claimed = u.claimed;
        (nextRate, nextCap) = nextOf(user);
        amount = _pending(u, nextRate, nextCap);
    }

    // ------------------------------------------------------------------ player

    function start() external {
        UserInfo storage u = _users[msg.sender];
        if (u.started) revert AlreadyStarted();
        (uint256 nr, uint256 nc) = nextOf(msg.sender);
        u.started = true;
        u.lastTime = uint64(block.timestamp);
        u.rate = nr;
        u.cap = nc;
        emit Started(msg.sender);
    }

    function claim() external nonReentrant {
        UserInfo storage u = _users[msg.sender];
        if (!u.started) revert NotStarted();
        (uint256 nr, uint256 nc) = nextOf(msg.sender);
        uint256 amount = _pending(u, nr, nc);
        (uint8 house, uint8 store) = buildings.levelsOf(msg.sender);
        // `base`: the same accrual window valued at the unboosted base rate (inferred event field).
        uint256 boost = houseBoostBps(house);
        uint256 base = boost == 0 ? amount : (amount * 10_000) / (10_000 + boost);
        u.rate = nr;
        u.cap = nc;
        u.lastTime = uint64(block.timestamp);
        u.claimed += amount;
        if (amount > 0) pxio.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount, base, house, store);
    }

    // ------------------------------------------------------------------ internal

    /// @dev Accrued amount under the "lower of old and new" rule: the applied rate/cap and the live
    ///      next rate/cap both bound the accrual until a claim applies the new values.
    function _pending(UserInfo storage u, uint256 nextRate, uint256 nextCap) internal view returns (uint256) {
        if (!u.started) return 0;
        uint256 effRate = u.rate < nextRate ? u.rate : nextRate;
        if (effRate == 0) return 0;
        uint256 effCap = u.cap < nextCap ? u.cap : nextCap;
        uint256 acc = (effRate * (block.timestamp - u.lastTime)) / 3600;
        return acc > effCap ? effCap : acc;
    }
}
