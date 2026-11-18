// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
    OPHIR Vault — purpose-built holding vault for the OPHIR liquidity allocation.

    Receives the 500,000,000 OPHR liquidity allocation in the deployment transaction.
    The owner (the sdw wallet) can withdraw any token at any time, and can later seed the
    PancakeSwap V3 pool through the LP locker: the locker's mintAndLock is onlyOwner and
    pulls the desired amounts from its caller, so the locker is owned by this vault and
    executeMintAndLock approves the locker and calls it — the locker pulls from the vault,
    refunds whatever it does not use back to the vault, and the position NFT is minted
    straight into the locker, where it stays forever.
*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPancakeV3PositionManager} from "./interfaces/IPancakeV3.sol";

interface IOphirLpLocker {
    function mintAndLock(
        IPancakeV3PositionManager.MintParams calldata p,
        address pool,
        uint160 expectedSqrtPriceX96
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

contract OphirVault is Ownable {
    using SafeERC20 for IERC20;

    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Approved(address indexed token, address indexed spender, uint256 amount);
    event Seeded(address indexed locker, uint256 indexed positionId, uint128 liquidity, uint256 amount0, uint256 amount1);

    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Withdraw any ERC-20 held by the vault. Owner only.
    function withdrawToken(address token_, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token_).safeTransfer(to, amount);
        emit Withdrawn(token_, to, amount);
    }

    /// @notice Set an ERC-20 allowance from the vault. Owner only.
    function approveToken(address token_, address spender, uint256 amount) external onlyOwner {
        if (spender == address(0)) revert ZeroAddress();
        IERC20(token_).forceApprove(spender, amount);
        emit Approved(token_, spender, amount);
    }

    /// @notice Seed (or add to) the V3 pool through the LP locker, spending this vault's own
    ///         balances. The locker pulls the desired amounts from the vault, refunds the
    ///         unused remainder to the vault, and locks the position NFT inside itself.
    ///         Owner only (and this vault must be the locker's owner).
    function executeMintAndLock(
        address locker,
        IPancakeV3PositionManager.MintParams calldata p,
        address pool,
        uint160 expectedSqrtPriceX96
    ) external onlyOwner returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (p.amount0Desired > 0) IERC20(p.token0).forceApprove(locker, p.amount0Desired);
        if (p.amount1Desired > 0) IERC20(p.token1).forceApprove(locker, p.amount1Desired);
        (tokenId, liquidity, amount0, amount1) = IOphirLpLocker(locker).mintAndLock(p, pool, expectedSqrtPriceX96);
        if (p.amount0Desired > 0) IERC20(p.token0).forceApprove(locker, 0);
        if (p.amount1Desired > 0) IERC20(p.token1).forceApprove(locker, 0);
        emit Seeded(locker, tokenId, liquidity, amount0, amount1);
    }
}
