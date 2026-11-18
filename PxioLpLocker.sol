// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
    PXIO LP Locker.
    Holds PancakeSwap V3 liquidity position NFTs forever.
    - Accepts position NFTs only from the PancakeSwap V3 NonfungiblePositionManager, or mints new positions
      straight into itself (mintAndLock: add-only, price-checked on-chain).
    - The only thing it can do with a position is collect trading fees, which always go to the payout wallet.
    - There is no function that decreases liquidity, burns, approves or transfers a position out. Not for anyone,
      not for the owner. The owner can only change the payout wallet that receives the fees.
*/

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPancakeV3PositionManager, IPancakeV3Factory, IPancakeV3Pool} from "./interfaces/IPancakeV3.sol";

contract PxioLpLocker is IERC721Receiver, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPancakeV3PositionManager public immutable positionManager;
    address public payout;

    uint256[] private _positions;
    mapping(uint256 => bool) public isLocked;

    event Locked(uint256 indexed tokenId);
    event FeesCollected(uint256 indexed tokenId, address indexed to, uint256 amount0, uint256 amount1);
    event PayoutSet(address indexed payout);

    error ZeroAddress();
    error NotPositionManager();
    error NotHeld();
    error BadPool();
    error PriceMismatch();

    constructor(address positionManager_, address payout_, address owner_) Ownable(owner_) {
        if (positionManager_ == address(0) || payout_ == address(0)) revert ZeroAddress();
        positionManager = IPancakeV3PositionManager(positionManager_);
        payout = payout_;
        emit PayoutSet(payout_);
    }

    /// @notice Accepts only PancakeSwap V3 position NFTs (safeTransferFrom into the locker).
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        _lock(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Registers a position that was minted straight to the locker (the position manager mints
    ///         without the ERC-721 receiver callback). Anyone can call; it only records what the locker holds.
    function track(uint256 tokenId) external {
        if (positionManager.ownerOf(tokenId) != address(this)) revert NotHeld();
        _lock(tokenId);
    }

    /// @notice Adds liquidity as a NEW position that is minted straight into this locker (it can only ever add).
    ///         Checks on-chain that `pool` is the factory pool for the pair and that its price is exactly
    ///         `expectedSqrtPriceX96`, so a pool initialized by someone else at another price is never funded.
    ///         Pulls the desired amounts from the caller and returns whatever the position manager did not use.
    function mintAndLock(IPancakeV3PositionManager.MintParams calldata p, address pool, uint160 expectedSqrtPriceX96)
        external
        onlyOwner
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // the position manager itself can never be passed as a "token" (no ERC-721 calls on it except mint/collect)
        if (p.token0 == address(positionManager) || p.token1 == address(positionManager)) revert BadPool();
        if (pool == address(0) || IPancakeV3Factory(positionManager.factory()).getPool(p.token0, p.token1, p.fee) != pool) {
            revert BadPool();
        }
        (uint160 cur,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (cur != expectedSqrtPriceX96) revert PriceMismatch();
        IERC20 t0 = IERC20(p.token0);
        IERC20 t1 = IERC20(p.token1);
        if (p.amount0Desired > 0) t0.safeTransferFrom(msg.sender, address(this), p.amount0Desired);
        if (p.amount1Desired > 0) t1.safeTransferFrom(msg.sender, address(this), p.amount1Desired);
        t0.forceApprove(address(positionManager), p.amount0Desired);
        t1.forceApprove(address(positionManager), p.amount1Desired);
        IPancakeV3PositionManager.MintParams memory m = p;
        m.recipient = address(this);
        (tokenId, liquidity, amount0, amount1) = positionManager.mint(m);
        _lock(tokenId);
        t0.forceApprove(address(positionManager), 0);
        t1.forceApprove(address(positionManager), 0);
        if (p.amount0Desired > amount0) t0.safeTransfer(msg.sender, p.amount0Desired - amount0);
        if (p.amount1Desired > amount1) t1.safeTransfer(msg.sender, p.amount1Desired - amount1);
    }

    /// @notice Collects all accrued fees of one position held by the locker to the payout wallet. Anyone can call.
    function collect(uint256 tokenId) public nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (positionManager.ownerOf(tokenId) != address(this)) revert NotHeld();
        address to = payout;
        (amount0, amount1) = positionManager.collect(
            IPancakeV3PositionManager.CollectParams({
                tokenId: tokenId,
                recipient: to,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit FeesCollected(tokenId, to, amount0, amount1);
    }

    /// @notice Collects fees of every locked position to the payout wallet.
    function collectAll() external {
        uint256 n = _positions.length;
        for (uint256 i; i < n; ++i) collect(_positions[i]);
    }

    function positions() external view returns (uint256[] memory) {
        return _positions;
    }

    function setPayout(address p) external onlyOwner {
        if (p == address(0)) revert ZeroAddress();
        payout = p;
        emit PayoutSet(p);
    }

    function _lock(uint256 tokenId) internal {
        if (isLocked[tokenId]) return;
        isLocked[tokenId] = true;
        _positions.push(tokenId);
        emit Locked(tokenId);
    }
}
