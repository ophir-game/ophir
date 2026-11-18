// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
    OPHIR Miners
    16,666 miners on BNB Smart Chain in five tiers: Digger 7000, Scribe 4700, Priest 2900, Vizier 1500, Solomon 566.
    https://ophirbnb.pages.dev

    - Mint is open to wallets holding a SPACE ID Agent ID (.ai), plus the partner wallet. Max 30 per wallet.
    - Token ids are assigned at mint (sealed). Each mint batch commits to a future block (mint block + 3); once that
      block exists anyone can reveal the batch. Its seed is the hash of that future block mixed with the batch data,
      and batches are revealed strictly in mint order, drawing tiers without replacement from the tiers still
      unassigned, so the final split is exact. Nobody, including the owner, can set or change a seed.
    - Soulbound: a miner can only move into and out of the official OPHIR market escrow.
    - Metadata is fully on-chain (base64 JSON).
*/

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IAgentIdRegistry {
    function balanceOf(address owner) external view returns (uint256);
}

contract OphirMiners is ERC721Enumerable, Ownable2Step, ReentrancyGuard {
    using Strings for uint256;

    // ------------------------------------------------------------------ constants
    uint256 public constant MAX_SUPPLY = 16_666;
    uint256 public constant MAX_PER_WALLET = 30;
    uint256 public constant PRICE_2_TO_10 = 0.0003 ether;
    uint256 public constant PRICE_11_TO_20 = 0.0006 ether;
    uint256 public constant PRICE_21_TO_30 = 0.0009 ether;
    uint8 public constant TIERS = 5;
    uint8 public constant UNREVEALED = 255;
    /// Blocks between a mint and the block whose hash seeds it. The hash does not exist when the mint is sent.
    uint256 public constant REVEAL_DELAY = 3;
    /// BLOCKHASH only reaches the last 256 blocks. A batch not revealed in time is re-anchored to a new future block.
    uint256 public constant BLOCKHASH_WINDOW = 256;
    /// Oldest ready batches a mint reveals on the way (keeps reveals going without a keeper, bounds mint gas).
    uint256 public constant AUTO_REVEAL_BATCHES = 2;
    /// Upper bound for one revealPending call.
    uint256 public constant MAX_REVEAL_BATCHES = 50;

    // ------------------------------------------------------------------ immutables
    IAgentIdRegistry public immutable agentRegistry;
    address public immutable partner;

    // ------------------------------------------------------------------ storage
    bool public mintOpen;
    address public payout;
    address public escrow; // the OPHIR market; set once

    // metadata
    string public imageBase; // ipfs://CID/  -> <base><tier>.png, <base>sealed.png
    string public tokenDescription;
    string public collectionDescription;
    string public externalUrl;
    string public xUrl;
    string public logoImage;
    string public bannerImage;

    uint256 public nextTokenId = 1;
    uint256 public revealedCount;
    uint16[5] private _tierRemaining = [7000, 4700, 2900, 1500, 566];
    mapping(address => uint256) public mintedBy;
    mapping(uint256 => uint256) private _tierPacked; // 32 tiers per slot, 8 bits each, stored as tier+1

    /// One mint transaction. Packed into a single storage slot.
    struct Batch {
        address minter;
        uint32 firstId;
        uint16 qty;
        uint40 targetBlock; // block whose hash seeds this batch (re-anchored if it left the BLOCKHASH window)
        bool revealed;
    }

    Batch[] private _batches;
    /// Oldest batch not yet revealed. Batches are revealed strictly in this order.
    uint256 public nextRevealBatch;

    // ------------------------------------------------------------------ events
    // Revealed(batchId, tokenId, tier) is what agents and the website wait on after a mint.
    event Minted(address indexed to, uint256 firstId, uint256 qty, uint256 cost, uint256 indexed batchId, uint256 targetBlock);
    event BatchRevealed(uint256 indexed batchId, uint256 indexed targetBlock);
    event Revealed(uint256 indexed batchId, uint256 indexed tokenId, uint8 tier);
    event BatchReanchored(uint256 indexed batchId, uint256 oldTargetBlock, uint256 newTargetBlock);
    event MintOpenSet(bool open);
    event PayoutSet(address indexed payout);
    event EscrowSet(address indexed escrow);
    event ContractURIUpdated(); // ERC-7572
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId); // ERC-4906

    // ------------------------------------------------------------------ errors
    error MintClosed();
    error BadQuantity();
    error SoldOut();
    error WalletLimit();
    error NoAgentId();
    error InsufficientPayment();
    error TransferFailed();
    error Soulbound();
    error NotEscrow();
    error EscrowAlreadySet();
    error UnknownBatch();
    error AlreadyRevealed();
    error NotReady();
    error ZeroAddress();

    constructor(
        address agentRegistry_,
        address partner_,
        address payout_,
        string memory imageBase_
    ) ERC721("OPHIR Miners", "OPHRM") Ownable(msg.sender) {
        if (agentRegistry_ == address(0) || partner_ == address(0) || payout_ == address(0)) revert ZeroAddress();
        agentRegistry = IAgentIdRegistry(agentRegistry_);
        partner = partner_;
        payout = payout_;
        imageBase = imageBase_;
        tokenDescription =
            "An OPHIR Miner. Dig for the legendary gold of Ophir: every miner earns $OPHR every hour in the OPHIR game.";
        collectionDescription =
            "OPHIR \\u2013 the gold of King Solomon. Build your house, fill your storage and wake the generator to earn $OPHR.";
        externalUrl = "https://ophirbnb.pages.dev";
        xUrl = "";
        logoImage = string.concat(imageBase_, "logo.png");
        bannerImage = string.concat(imageBase_, "banner.png");
    }

    // ================================================================== views

    function hasAgentId(address a) public view returns (bool) {
        if (address(agentRegistry).code.length == 0) return false;
        try agentRegistry.balanceOf(a) returns (uint256 b) {
            return b > 0;
        } catch {
            return false;
        }
    }

    function canMint(address a) public view returns (bool) {
        return a == partner || hasAgentId(a);
    }

    /// @notice Price of a wallet's mint number `n` (1-based): #1 free, #2-10, #11-20, #21-30.
    function unitPrice(uint256 n) public pure returns (uint256) {
        if (n <= 1) return 0;
        if (n <= 10) return PRICE_2_TO_10;
        if (n <= 20) return PRICE_11_TO_20;
        return PRICE_21_TO_30;
    }

    /// @notice BNB cost for `a` to mint `qty` more now.
    function quote(address a, uint256 qty) public view returns (uint256 cost) {
        uint256 m = mintedBy[a];
        for (uint256 i = 1; i <= qty; ++i) cost += unitPrice(m + i);
    }

    /// @notice How many more `a` can mint right now.
    function mintableBy(address a) external view returns (uint256) {
        if (!canMint(a)) return 0;
        uint256 left = MAX_PER_WALLET - mintedBy[a];
        uint256 supplyLeft = MAX_SUPPLY - (nextTokenId - 1);
        return left < supplyLeft ? left : supplyLeft;
    }

    function totalMinted() public view returns (uint256) {
        return nextTokenId - 1;
    }

    /// @notice Unassigned count per tier (tiers not yet drawn by any reveal).
    function remainingByTier() external view returns (uint16[5] memory) {
        return _tierRemaining;
    }

    /// @notice Revealed count per tier.
    function revealedByTier() external view returns (uint256[5] memory r) {
        uint16[5] memory s = [uint16(7000), 4700, 2900, 1500, 566];
        for (uint256 t; t < TIERS; ++t) r[t] = s[t] - _tierRemaining[t];
    }

    /// @notice Tier 0..4, or 255 while sealed. Reverts for a token that does not exist.
    function tierOf(uint256 tokenId) public view returns (uint8) {
        _requireOwned(tokenId);
        uint8 v = uint8(_tierPacked[tokenId >> 5] >> ((tokenId & 31) * 8));
        return v == 0 ? UNREVEALED : v - 1;
    }

    function isRevealed(uint256 tokenId) external view returns (bool) {
        return tierOf(tokenId) != UNREVEALED;
    }

    function tokensOfOwner(address o) public view returns (uint256[] memory ids) {
        uint256 n = balanceOf(o);
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = tokenOfOwnerByIndex(o, i);
    }

    /// @notice Revealed miners per tier held by `o` (escrowed listings are held by the market, not counted).
    function tiersOf(address o) external view returns (uint256[5] memory counts) {
        uint256 n = balanceOf(o);
        for (uint256 i; i < n; ++i) {
            uint8 t = tierOf(tokenOfOwnerByIndex(o, i));
            if (t < TIERS) counts[t] += 1;
        }
    }

    function sealedOf(address o) external view returns (uint256 count) {
        uint256 n = balanceOf(o);
        for (uint256 i; i < n; ++i) {
            if (tierOf(tokenOfOwnerByIndex(o, i)) == UNREVEALED) count += 1;
        }
    }

    function batchCount() external view returns (uint256) {
        return _batches.length;
    }

    function batch(uint256 id) external view returns (Batch memory) {
        if (id >= _batches.length) revert UnknownBatch();
        return _batches[id];
    }

    /// @notice Batches minted but not revealed yet.
    function pendingBatches() public view returns (uint256) {
        return _batches.length - nextRevealBatch;
    }

    /// @notice Sealed tokens (minted, tier not drawn yet).
    function pendingTokens() public view returns (uint256) {
        return (nextTokenId - 1) - revealedCount;
    }

    /// @notice True when the oldest pending batch can be processed now (revealed, or re-anchored if it expired).
    ///         A keeper calls revealPending only when this is true.
    function revealReady() public view returns (bool) {
        uint256 h = nextRevealBatch;
        return h < _batches.length && block.number > _batches[h].targetBlock;
    }

    /// @notice Pending batches (from the oldest) that would be revealed by revealPending right now, capped at `max`.
    function readyBatches(uint256 max) external view returns (uint256 n) {
        uint256 h = nextRevealBatch;
        uint256 len = _batches.length;
        while (n < max && h + n < len) {
            uint256 tb = _batches[h + n].targetBlock;
            if (block.number <= tb || block.number > tb + BLOCKHASH_WINDOW) break;
            ++n;
        }
    }

    function tierName(uint8 t) public pure returns (string memory) {
        if (t == 0) return "Digger";
        if (t == 1) return "Scribe";
        if (t == 2) return "Priest";
        if (t == 3) return "Vizier";
        if (t == 4) return "Solomon";
        return "Sealed";
    }

    function miningRate(uint8 t) public pure returns (uint256) {
        if (t == 0) return 10;
        if (t == 1) return 19;
        if (t == 2) return 35;
        if (t == 3) return 64;
        if (t == 4) return 120;
        return 0;
    }

    function tierSupply(uint8 t) public pure returns (uint256) {
        if (t == 0) return 7000;
        if (t == 1) return 4700;
        if (t == 2) return 2900;
        if (t == 3) return 1500;
        if (t == 4) return 566;
        return 0;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        uint8 t = tierOf(tokenId);
        string memory attrs;
        string memory image;
        if (t == UNREVEALED) {
            image = string.concat(imageBase, "sealed.png");
            attrs = '[{"trait_type":"Tier","value":"Sealed"}]';
        } else {
            image = string.concat(imageBase, uint256(t).toString(), ".png");
            attrs = string.concat(
                '[{"trait_type":"Tier","value":"', tierName(t),
                '"},{"trait_type":"Rarity","display_type":"number","value":', uint256(t + 1).toString(),
                '},{"trait_type":"Mining rate ($OPHR/h)","display_type":"number","value":', miningRate(t).toString(),
                '},{"trait_type":"Tier supply","display_type":"number","value":', tierSupply(t).toString(), "}]"
            );
        }
        string memory json = string.concat(
            '{"name":"OPHIR Miner #', tokenId.toString(),
            '","description":"', tokenDescription,
            '","external_url":"', externalUrl,
            '","image":"', image,
            '","attributes":', attrs, "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice ERC-7572 collection metadata.
    function contractURI() external view returns (string memory) {
        string memory json = string.concat(
            '{"name":"OPHIR Miners","description":"', collectionDescription,
            '","image":"', logoImage,
            '","banner_image":"', bannerImage,
            '","external_link":"', externalUrl,
            '","x":"', xUrl, '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == bytes4(0x49064906) || super.supportsInterface(id); // ERC-4906
    }

    // ================================================================== mint

    /// @notice Mints `qty` sealed miners. Also reveals up to AUTO_REVEAL_BATCHES of the oldest ready batches
    ///         (never this one: its target block is in the future), so reveals keep going even without a keeper.
    function mint(uint256 qty) external payable nonReentrant {
        if (!mintOpen) revert MintClosed();
        if (qty == 0 || qty > MAX_PER_WALLET) revert BadQuantity();
        uint256 first = nextTokenId;
        if (first - 1 + qty > MAX_SUPPLY) revert SoldOut();
        if (!canMint(msg.sender)) revert NoAgentId();
        uint256 already = mintedBy[msg.sender];
        if (already + qty > MAX_PER_WALLET) revert WalletLimit();

        uint256 cost = quote(msg.sender, qty);
        if (msg.value < cost) revert InsufficientPayment();

        // effects
        _processPending(_batches.length, AUTO_REVEAL_BATCHES);

        mintedBy[msg.sender] = already + qty;
        nextTokenId = first + qty;
        for (uint256 i; i < qty; ++i) _mint(msg.sender, first + i);

        uint256 batchId = _batches.length;
        uint256 target = block.number + REVEAL_DELAY;
        _batches.push(
            Batch({minter: msg.sender, firstId: uint32(first), qty: uint16(qty), targetBlock: uint40(target), revealed: false})
        );
        emit Minted(msg.sender, first, qty, cost, batchId, target);

        // interactions
        if (cost > 0) {
            (bool ok,) = payout.call{value: cost}("");
            if (!ok) revert TransferFailed();
        }
        if (msg.value > cost) {
            (bool ok2,) = msg.sender.call{value: msg.value - cost}("");
            if (!ok2) revert TransferFailed();
        }
    }

    // ================================================================== reveal (anyone)

    /// @notice Reveals every pending batch up to and including `batchId`, oldest first, once their target blocks
    ///         have passed. Anyone can call it; the result does not depend on who calls or when.
    ///         If a batch's target block left the 256-block BLOCKHASH window it is re-anchored instead (event) and
    ///         the call returns without reverting so the re-anchor sticks.
    function reveal(uint256 batchId) external returns (uint256 revealedN) {
        if (batchId >= _batches.length) revert UnknownBatch();
        if (batchId < nextRevealBatch) revert AlreadyRevealed();
        if (block.number <= _batches[batchId].targetBlock) revert NotReady();
        uint256 reanchoredN;
        (revealedN, reanchoredN) = _processPending(batchId + 1, type(uint256).max);
        if (revealedN + reanchoredN == 0) revert NotReady();
    }

    /// @notice Reveals (or re-anchors, if expired) up to `maxBatches` of the oldest pending batches.
    ///         0 or anything above MAX_REVEAL_BATCHES means MAX_REVEAL_BATCHES. Reverts NotReady if nothing to do.
    function revealPending(uint256 maxBatches) external returns (uint256 revealedN, uint256 reanchoredN) {
        if (maxBatches == 0 || maxBatches > MAX_REVEAL_BATCHES) maxBatches = MAX_REVEAL_BATCHES;
        (revealedN, reanchoredN) = _processPending(_batches.length, maxBatches);
        if (revealedN + reanchoredN == 0) revert NotReady();
    }

    /// @dev Walks pending batches from the oldest, strictly in mint order, and never reverts:
    ///      - target block not passed yet: stop (nothing after it may be revealed first);
    ///      - target hash available: reveal;
    ///      - target hash unavailable (more than 256 blocks ago): re-anchor to block.number + REVEAL_DELAY. Nothing
    ///        after it is revealed in this pass (order), but later expired batches are re-anchored too.
    ///      Strict order makes every outcome a fixed function of the target block hashes, so a caller cannot
    ///      change results by choosing which batch to reveal first.
    function _processPending(uint256 end, uint256 maxSteps) internal returns (uint256 revealedN, uint256 reanchoredN) {
        uint256 head = nextRevealBatch;
        uint256 i = head;
        bool blocked;
        while (i < end && revealedN + reanchoredN < maxSteps) {
            Batch storage bt = _batches[i];
            uint256 tb = bt.targetBlock;
            if (block.number <= tb) break;
            bytes32 bh = blockhash(tb); // zero once tb is more than 256 blocks old
            if (bh == bytes32(0)) {
                uint256 nt = block.number + REVEAL_DELAY;
                bt.targetBlock = uint40(nt);
                emit BatchReanchored(i, tb, nt);
                ++reanchoredN;
                blocked = true;
            } else {
                if (blocked) break;
                _revealBatch(i, bt, tb, bh);
                ++revealedN;
                head = i + 1;
            }
            ++i;
        }
        if (head != nextRevealBatch) nextRevealBatch = head;
    }

    /// @dev Seed = keccak256(blockhash(targetBlock), batchId, minter, firstId, qty, this). The target block did not
    ///      exist when the mint was sent, and the owner has no input to it.
    ///      Exactness: sum(_tierRemaining) = MAX_SUPPLY - revealedCount >= minted - revealedCount = sealed tokens,
    ///      so every draw has a non-empty pool, and after all 16,666 are revealed every tier count is exactly 0.
    function _revealBatch(uint256 batchId, Batch storage bt, uint256 tb, bytes32 bh) internal {
        bt.revealed = true;
        uint256 first = bt.firstId;
        uint256 qty = bt.qty;
        uint256 seed = uint256(keccak256(abi.encode(bh, batchId, bt.minter, first, qty, address(this))));
        _assignTiers(batchId, first, qty, seed);
        revealedCount += qty;
        emit BatchRevealed(batchId, tb);
        emit BatchMetadataUpdate(first, first + qty - 1);
    }

    function _assignTiers(uint256 batchId, uint256 first, uint256 qty, uint256 seed) internal {
        uint16[5] memory rem = _tierRemaining;
        uint256 left = MAX_SUPPLY - revealedCount;
        uint256 slot = type(uint256).max;
        uint256 packed;
        for (uint256 i; i < qty; ++i) {
            uint256 tokenId = first + i;
            uint8 t = _draw(rem, uint256(keccak256(abi.encode(seed, i))) % left);
            unchecked {
                rem[t] -= 1;
                left -= 1;
            }
            uint256 s = tokenId >> 5;
            if (s != slot) {
                if (slot != type(uint256).max) _tierPacked[slot] = packed;
                slot = s;
                packed = _tierPacked[s];
            }
            packed |= uint256(t + 1) << ((tokenId & 31) * 8);
            emit Revealed(batchId, tokenId, t);
        }
        _tierPacked[slot] = packed;
        _tierRemaining = rem;
    }

    /// @dev Maps x in [0, sum(rem)) to a tier through the remaining counts (draw without replacement).
    function _draw(uint16[5] memory rem, uint256 x) internal pure returns (uint8 t) {
        uint256 acc = rem[0];
        while (x >= acc) {
            unchecked {
                ++t;
            }
            acc += rem[t];
        }
    }

    // ================================================================== soulbound + escrow

    /// @notice Called by the market escrow to take a listed miner from its owner.
    function escrowPull(address from, uint256 tokenId) external {
        address e = escrow;
        if (msg.sender != e || e == address(0)) revert NotEscrow();
        _transfer(from, e, tokenId);
    }

    /// @dev Mint is always allowed. Any other move must be made by the escrow and must go into or out of it.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0)) {
            address e = escrow;
            if (e == address(0) || msg.sender != e || (to != e && from != e) || to == address(0)) revert Soulbound();
        }
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override(ERC721, IERC721) {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override(ERC721, IERC721) {
        revert Soulbound();
    }

    // ================================================================== owner

    function setMintOpen(bool open) external onlyOwner {
        mintOpen = open;
        emit MintOpenSet(open);
    }

    function setPayout(address p) external onlyOwner {
        if (p == address(0)) revert ZeroAddress();
        payout = p;
        emit PayoutSet(p);
    }

    /// @notice One-time wiring of the market escrow. Can never be changed afterwards.
    function setEscrow(address e) external onlyOwner {
        if (e == address(0)) revert ZeroAddress();
        if (escrow != address(0)) revert EscrowAlreadySet();
        escrow = e;
        emit EscrowSet(e);
    }

    function setImageBase(string calldata v) external onlyOwner {
        imageBase = v;
        _metadataChanged();
    }

    function setTokenDescription(string calldata v) external onlyOwner {
        tokenDescription = v;
        _metadataChanged();
    }

    function setCollectionDescription(string calldata v) external onlyOwner {
        collectionDescription = v;
        _metadataChanged();
    }

    function setExternalUrl(string calldata v) external onlyOwner {
        externalUrl = v;
        _metadataChanged();
    }

    function setXUrl(string calldata v) external onlyOwner {
        xUrl = v;
        _metadataChanged();
    }

    function setLogoImage(string calldata v) external onlyOwner {
        logoImage = v;
        _metadataChanged();
    }

    function setBannerImage(string calldata v) external onlyOwner {
        bannerImage = v;
        _metadataChanged();
    }

    function _metadataChanged() internal {
        emit BatchMetadataUpdate(1, MAX_SUPPLY);
        emit ContractURIUpdated();
    }
}
