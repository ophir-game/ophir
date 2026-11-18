// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal interface to OphirMiners as used by this market.
///         OphirMiners is soulbound: the only way an NFT enters escrow is
///         `escrowPull` (callable only by the one-time-set escrow = this
///         market), and transfers out of the escrow address are permitted.
interface IOphirMiners {
    function ownerOf(uint256 tokenId) external view returns (address);
    function escrowPull(address from, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/**
 * @title OphirMarket — escrow marketplace for OPHIR Miners.
 * @notice Escrow market, BNB-denominated, seller-set prices:
 *           - flat action fee 0.0005 BNB on LIST and on DELIST only;
 *           - BUY pays exactly the listing price — no action fee;
 *           - 5% royalty of the price to the owner at settlement
 *             (seller receives 95% immediately);
 *           - action fees accrue in the contract; owner sweeps them with
 *             withdrawFees().
 *         NO minimum listing price: sellers may list at any price > 0.
 */
contract OphirMarket {
    IOphirMiners public immutable nft;
    address public owner;

    uint256 public constant ACTION_FEE = 0.0005 ether;
    uint256 public constant ROYALTY_BPS = 500; // 5%
    uint256 internal constant BPS_DENOM = 10_000;

    struct Listing {
        address seller;
        uint256 price;
    }

    mapping(uint256 => Listing) public listings;
    uint256 public feesAccrued;
    uint256 public totalSales;
    uint256 public totalVolume;

    bool private _locked;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Delisted(uint256 indexed tokenId, address indexed seller);
    event Sold(
        uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price, uint256 royalty
    );
    event FeesWithdrawn(address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "Reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address nft_, address initialOwner_) {
        require(nft_ != address(0) && initialOwner_ != address(0), "Invalid");
        nft = IOphirMiners(nft_);
        owner = initialOwner_;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice List a token for sale. The NFT moves into escrow here via the
    ///         miners contract's escrowPull. Caller pays exactly the action fee.
    function list(uint256 tokenId, uint256 price) external payable nonReentrant {
        require(msg.value == ACTION_FEE, "Action fee is 0.0005 BNB");
        require(price > 0, "Price must be > 0");
        require(nft.ownerOf(tokenId) == msg.sender, "Not token owner");
        require(listings[tokenId].seller == address(0), "Already listed");
        listings[tokenId] = Listing(msg.sender, price);
        feesAccrued += msg.value;
        nft.escrowPull(msg.sender, tokenId);
        emit Listed(tokenId, msg.sender, price);
    }

    /// @notice Cancel a listing; the escrowed NFT returns to the seller.
    ///         Caller pays exactly the action fee.
    function delist(uint256 tokenId) external payable nonReentrant {
        require(msg.value == ACTION_FEE, "Action fee is 0.0005 BNB");
        Listing memory l = listings[tokenId];
        require(l.seller == msg.sender, "Not seller");
        delete listings[tokenId];
        feesAccrued += msg.value;
        nft.transferFrom(address(this), msg.sender, tokenId);
        emit Delisted(tokenId, msg.sender);
    }

    /// @notice Buy a listed token. Caller pays exactly the listing price —
    ///         NO action fee. 95% of the price goes to the seller and the 5%
    ///         royalty goes to the owner, both at settlement.
    function buy(uint256 tokenId) external payable nonReentrant {
        Listing memory l = listings[tokenId];
        require(l.seller != address(0), "Not listed");
        require(msg.sender != l.seller, "Cannot buy own listing");
        require(msg.value == l.price, "Pay exact price");

        delete listings[tokenId];

        uint256 royalty = (l.price * ROYALTY_BPS) / BPS_DENOM;
        uint256 sellerGets = l.price - royalty;
        totalSales += 1;
        totalVolume += l.price;

        nft.transferFrom(address(this), msg.sender, tokenId);

        (bool okSeller,) = l.seller.call{value: sellerGets}("");
        require(okSeller, "Pay seller failed");
        (bool okOwner,) = owner.call{value: royalty}("");
        require(okOwner, "Pay royalty failed");
        emit Sold(tokenId, l.seller, msg.sender, l.price, royalty);
    }

    /// @notice Sweep accrued action fees to the owner.
    function withdrawFees() external onlyOwner nonReentrant {
        uint256 amount = feesAccrued;
        require(amount > 0, "Nothing to withdraw");
        feesAccrued = 0;
        (bool ok,) = owner.call{value: amount}("");
        require(ok, "Withdraw failed");
        emit FeesWithdrawn(owner, amount);
    }
}
