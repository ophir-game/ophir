// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
    OPHIR Buildings.
    Players upgrade their House (Lv 1..10) and Storage (Lv 1..15) one level at a time, paying $OPHR.
    Every building starts at Lv 1. The OPHR paid stays in this contract and the owner can withdraw it.
    Default costs mirror the game (HOUSE and STORAGE tables), 18 decimals.
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract OphirBuildings is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant HOUSE = 0;
    uint8 public constant STORAGE = 1;
    uint8 public constant HOUSE_MAX_LEVEL = 10;
    uint8 public constant STORAGE_MAX_LEVEL = 15;

    IERC20 public immutable pxio;

    /// cost[building][level] = OPHR to reach `level` (level 2..max; index 0 and 1 unused)
    mapping(uint8 => mapping(uint8 => uint256)) private _cost;
    /// stored level; 0 means never upgraded (= Lv 1)
    mapping(address => mapping(uint8 => uint8)) private _level;

    event Upgraded(address indexed user, uint8 indexed building, uint8 toLevel, uint256 cost);
    event CostSet(uint8 indexed building, uint8 indexed level, uint256 cost);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error BadBuilding();
    error BadLevel();
    error LengthMismatch();

    constructor(address pxio_, address owner_) Ownable(owner_) {
        if (pxio_ == address(0)) revert ZeroAddress();
        pxio = IERC20(pxio_);
        // House: cost to reach Lv 2..10
        uint32[9] memory h = [uint32(400), 1500, 4000, 8000, 15000, 26000, 42000, 65000, 100000];
        for (uint8 i; i < 9; ++i) _setCost(HOUSE, i + 2, uint256(h[i]) * 1 ether);
        // Storage: cost to reach Lv 2..15
        uint32[14] memory s =
            [uint32(300), 800, 1800, 3500, 6000, 10000, 15000, 22000, 32000, 45000, 62000, 85000, 115000, 155000];
        for (uint8 i; i < 14; ++i) _setCost(STORAGE, i + 2, uint256(s[i]) * 1 ether);
    }

    // ------------------------------------------------------------------ views

    function maxLevel(uint8 building) public pure returns (uint8) {
        if (building == HOUSE) return HOUSE_MAX_LEVEL;
        if (building == STORAGE) return STORAGE_MAX_LEVEL;
        revert BadBuilding();
    }

    function levelOf(address user, uint8 building) public view returns (uint8) {
        maxLevel(building);
        uint8 l = _level[user][building];
        return l == 0 ? 1 : l;
    }

    function levelsOf(address user) external view returns (uint8 house, uint8 storage_) {
        return (levelOf(user, HOUSE), levelOf(user, STORAGE));
    }

    function costOf(uint8 building, uint8 level) external view returns (uint256) {
        if (level < 2 || level > maxLevel(building)) revert BadLevel();
        return _cost[building][level];
    }

    /// @notice Full cost table for a building, index = level (0 and 1 are always 0).
    function costTable(uint8 building) external view returns (uint256[] memory t) {
        uint8 m = maxLevel(building);
        t = new uint256[](uint256(m) + 1);
        for (uint8 l = 2; l <= m; ++l) t[l] = _cost[building][l];
    }

    // ------------------------------------------------------------------ player

    function upgrade(uint8 building, uint8 toLevel) external nonReentrant {
        uint8 m = maxLevel(building);
        uint8 cur = levelOf(msg.sender, building);
        if (toLevel != cur + 1 || toLevel > m) revert BadLevel();
        uint256 c = _cost[building][toLevel];
        _level[msg.sender][building] = toLevel;
        if (c > 0) pxio.safeTransferFrom(msg.sender, address(this), c);
        emit Upgraded(msg.sender, building, toLevel, c);
    }

    // ------------------------------------------------------------------ owner

    function setCost(uint8 building, uint8 level, uint256 cost) external onlyOwner {
        if (level < 2 || level > maxLevel(building)) revert BadLevel();
        _setCost(building, level, cost);
    }

    /// @param costs costs for levels 2..max in order (length max-1)
    function setCosts(uint8 building, uint256[] calldata costs) external onlyOwner {
        uint8 m = maxLevel(building);
        if (costs.length != uint256(m) - 1) revert LengthMismatch();
        for (uint8 i; i < costs.length; ++i) _setCost(building, i + 2, costs[i]);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function _setCost(uint8 building, uint8 level, uint256 cost) internal {
        _cost[building][level] = cost;
        emit CostSet(building, level, cost);
    }
}
