// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title HOLDINGS (HODL)
/// @notice 1,000 fully onchain generative NFTs exploring the difference between holding cryptocurrency and cash.
///         Every token shows a conceptual balance. ETH and IMD holdings are immutable forever. CASH holdings can only
///         ever go down, through `outage`, which anyone may call.
/// @dev    The balances are artwork, not funds. Nothing in this contract (owner included) can raise a balance, reset it,
///         restore it, or change a token's holding type or currency. There is no proxy, no baseURI and no metadata
///         override: `tokenURI` is rendered from storage on every call.
///
///         RANDOMNESS (Sepolia testing only): the holding type and balance are derived from
///         `keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), block.timestamp, msg.sender, tokenId,
///         address(this), block.chainid))`. This is pseudo-randomness. A block proposer/builder chooses `prevrandao`
///         (within the RANDAO reveal it can withhold) and the timestamp, and every other input is public before the
///         transaction runs. A contract minter can compute the outcome in the same transaction and revert when it does
///         not like it (for example, to only keep ETH holdings or large balances), paying only gas. See README,
///         "Randomness and its manipulation risks". A production deployment that wants unbiased outcomes should
///         replace this with a verifiable randomness source (e.g. Chainlink VRF) or a commit-reveal scheme.
contract Holdings is ERC721, Ownable2Step, ReentrancyGuard, IERC4906 {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    /// @notice The kind of holding a token represents. Fixed at mint, never changes.
    enum HoldingType {
        ETH,
        IMD,
        CASH
    }

    /// @dev Packed in one storage slot. `originalBalance` is written once at mint and never again.
    ///      `currentBalance` equals `originalBalance` for ETH/IMD forever; for CASH it only decreases.
    struct Holding {
        HoldingType holdingType;
        uint64 originalBalance;
        uint64 currentBalance;
        uint32 outages;
    }

    /// @notice Maximum number of tokens across both payment methods.
    uint256 public constant MAX_SUPPLY = 1_000;
    /// @notice Exact ETH price per mint: 0.00056 ETH.
    uint256 public constant ETH_PRICE = 0.00056 ether;
    /// @notice IMD price per mint, in hundredths of one whole IMD: 35 = 0.35 IMD. Scaled by the token's decimals.
    uint256 public constant IMD_PRICE_HUNDREDTHS = 35;
    /// @notice Smallest generated balance (inclusive).
    uint256 public constant MIN_BALANCE = 1;
    /// @notice Largest generated balance (inclusive).
    uint256 public constant MAX_BALANCE = 1_000_000_000;

    /// @dev SVG canvas side in user units.
    uint256 private constant CANVAS = 1000;
    /// @dev Largest font size used for short strings.
    uint256 private constant MAX_FONT_SIZE = 320;
    /// @dev font-size = FONT_SCALE / characters. The monospace face advances 0.6em per glyph, so a line is
    ///      0.6 * 1440 = 864 units wide whatever its length: centred with at least 68 units of margin on each side.
    uint256 private constant FONT_SCALE = 1440;

    /// @notice The IMD ERC-20 accepted by `mintWithIMD`. Set once in the constructor.
    IERC20 public immutable IMD;

    /// @notice Number of tokens minted. Token ids run from 1 to `totalSupply()`.
    uint256 public totalSupply;

    mapping(uint256 tokenId => Holding) private _holdings;

    /// @notice A CASH holding's displayed balance was lowered.
    event Outage(uint256 indexed tokenId, uint256 previousBalance, uint256 newBalance, address indexed caller);
    /// @notice A token was minted with its permanent holding type and initial balance.
    event HoldingMinted(
        uint256 indexed tokenId, address indexed minter, HoldingType holdingType, uint256 balance, bool paidWithIMD
    );
    /// @notice The owner withdrew mint proceeds.
    event ETHWithdrawn(address indexed to, uint256 amount);
    event IMDWithdrawn(address indexed to, uint256 amount);

    error ZeroIMDToken();
    error SoldOut();
    error IncorrectETHPayment(uint256 sent, uint256 required);
    error UnsupportedIMDDecimals(uint8 decimals);
    error IMDAllowanceTooLow(uint256 allowance, uint256 required);
    error IMDBalanceTooLow(uint256 balance, uint256 required);
    error IMDPaymentShort(uint256 received, uint256 required);
    error NotCashHolding(uint256 tokenId, HoldingType holdingType);
    error BalanceMustDecrease(uint256 currentBalance, uint256 requestedBalance);
    error NothingToWithdraw();
    error ETHTransferFailed();
    error RenounceDisabled();

    /// @param owner_ Receives withdrawals; the only account allowed to call `withdrawETH` / `withdrawIMD`.
    /// @param imdToken_ The IMD ERC-20 (on Sepolia: the MockIMD deployed alongside, as no official Sepolia IMD exists).
    /// @dev Calls no other contract, so it runs on an empty chain. The token is checked on first use.
    constructor(address owner_, address imdToken_) ERC721("HOLDINGS", "HODL") Ownable(owner_) {
        if (imdToken_ == address(0)) revert ZeroIMDToken();
        IMD = IERC20(imdToken_);
    }

    // ------------------------------------------------------------------
    // Minting
    // ------------------------------------------------------------------

    /// @notice Mint one token for exactly 0.00056 ETH. 50% ETH holding, 50% CASH holding.
    function mint() external payable nonReentrant returns (uint256 tokenId) {
        if (msg.value != ETH_PRICE) revert IncorrectETHPayment(msg.value, ETH_PRICE);
        tokenId = _nextTokenId();
        uint256 rand = _random(tokenId);
        HoldingType holdingType = ((rand >> 128) & 1) == 0 ? HoldingType.ETH : HoldingType.CASH;
        _record(tokenId, holdingType, rand, false);
        _safeMint(msg.sender, tokenId);
    }

    /// @notice Mint one token for exactly 0.35 IMD, pulled from the caller (approve this contract first).
    ///         Always produces an IMD holding.
    function mintWithIMD() external nonReentrant returns (uint256 tokenId) {
        uint256 price = imdPrice();
        uint256 allowance = IMD.allowance(msg.sender, address(this));
        if (allowance < price) revert IMDAllowanceTooLow(allowance, price);
        uint256 payerBalance = IMD.balanceOf(msg.sender);
        if (payerBalance < price) revert IMDBalanceTooLow(payerBalance, price);

        tokenId = _nextTokenId();
        _record(tokenId, HoldingType.IMD, _random(tokenId), true);

        uint256 before = IMD.balanceOf(address(this));
        IMD.safeTransferFrom(msg.sender, address(this), price);
        uint256 received = IMD.balanceOf(address(this)) - before;
        if (received != price) revert IMDPaymentShort(received, price);

        _safeMint(msg.sender, tokenId);
    }

    /// @notice The IMD amount (in the token's smallest unit) one mint costs: 0.35 * 10**decimals.
    function imdPrice() public view returns (uint256) {
        uint8 decimals = IERC20Metadata(address(IMD)).decimals();
        if (decimals < 2 || decimals > 36) revert UnsupportedIMDDecimals(decimals);
        return IMD_PRICE_HUNDREDTHS * 10 ** (uint256(decimals) - 2);
    }

    // ------------------------------------------------------------------
    // Outage
    // ------------------------------------------------------------------

    /// @notice Lower the displayed balance of a CASH holding. Anyone may call. `newBalance` must be strictly lower than
    ///         the current balance and may be zero. Reverts for ETH and IMD holdings.
    function outage(uint256 tokenId, uint256 newBalance) external {
        _requireOwned(tokenId);
        Holding storage h = _holdings[tokenId];
        if (h.holdingType != HoldingType.CASH) revert NotCashHolding(tokenId, h.holdingType);
        uint256 previous = h.currentBalance;
        if (newBalance >= previous) revert BalanceMustDecrease(previous, newBalance);
        // newBalance < previous <= MAX_BALANCE, so it always fits in uint64.
        h.currentBalance = SafeCast.toUint64(newBalance);
        unchecked {
            h.outages += 1; // at most MAX_BALANCE outages per token, far below 2**32
        }
        emit Outage(tokenId, previous, newBalance, msg.sender);
        emit MetadataUpdate(tokenId);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Holding type, original balance, current balance and currency ("ETH", "IMD" or "USD") of a token.
    function getHolding(uint256 tokenId)
        external
        view
        returns (HoldingType holdingType, uint256 originalBalance, uint256 currentBalance, string memory currency)
    {
        _requireOwned(tokenId);
        Holding memory h = _holdings[tokenId];
        return (h.holdingType, h.originalBalance, h.currentBalance, _currency(h.holdingType));
    }

    /// @notice How many outages a token has suffered (always 0 for ETH and IMD holdings).
    function outageCount(uint256 tokenId) external view returns (uint256) {
        _requireOwned(tokenId);
        return _holdings[tokenId].outages;
    }

    /// @notice The text the artwork shows, e.g. "82,194,012 ETH", "82,194,012 IMD" or "$82,194,012".
    function displayText(uint256 tokenId) public view returns (string memory) {
        _requireOwned(tokenId);
        Holding memory h = _holdings[tokenId];
        return _displayText(h.holdingType, h.currentBalance);
    }

    /// @notice The raw SVG artwork for a token, rendered from its current balance.
    function tokenSVG(uint256 tokenId) public view returns (string memory) {
        return _svg(displayText(tokenId));
    }

    /// @notice Fully onchain metadata: base64 JSON with a base64 SVG image, rendered from storage on every call.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Holding memory h = _holdings[tokenId];
        string memory typeName = _typeName(h.holdingType);
        string memory currency = _currency(h.holdingType);
        string memory text = _displayText(h.holdingType, h.currentBalance);
        string memory image = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(_svg(text))));
        string memory original = uint256(h.originalBalance).toString();
        string memory current = uint256(h.currentBalance).toString();

        string memory attributes = string.concat(
            '[{"trait_type":"Holding Type","value":"',
            typeName,
            '"},{"trait_type":"Currency","value":"',
            currency,
            '"},{"trait_type":"Initial Balance","display_type":"number","value":',
            original,
            '},{"trait_type":"Current Balance","display_type":"number","value":',
            current,
            '},{"trait_type":"Outages","display_type":"number","value":',
            uint256(h.outages).toString(),
            "}]"
        );
        string memory json = string.concat(
            '{"name":"HOLDINGS #',
            tokenId.toString(),
            '","description":"',
            _description(h.holdingType),
            '","holding_type":"',
            typeName,
            '","currency":"',
            currency,
            '","initial_balance":',
            original,
            ',"current_balance":',
            current,
            ',"display":"',
            text,
            '","image":"',
            image,
            '","attributes":',
            attributes,
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == bytes4(0x49064906) || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    /// @notice Send all ETH mint proceeds to the owner. Owner only.
    function withdrawETH() external nonReentrant onlyOwner {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        address to = owner();
        emit ETHWithdrawn(to, amount);
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
    }

    /// @notice Send all IMD mint proceeds to the owner. Owner only.
    function withdrawIMD() external nonReentrant onlyOwner {
        uint256 amount = IMD.balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();
        address to = owner();
        emit IMDWithdrawn(to, amount);
        IMD.safeTransfer(to, amount);
    }

    /// @notice Disabled: renouncing would strand mint proceeds forever. Use the two-step `transferOwnership`.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _nextTokenId() private returns (uint256 tokenId) {
        if (totalSupply >= MAX_SUPPLY) revert SoldOut();
        unchecked {
            tokenId = ++totalSupply;
        }
    }

    function _record(uint256 tokenId, HoldingType holdingType, uint256 rand, bool paidWithIMD) private {
        uint256 balance = MIN_BALANCE + (rand % MAX_BALANCE);
        uint64 packed = SafeCast.toUint64(balance);
        _holdings[tokenId] =
            Holding({holdingType: holdingType, originalBalance: packed, currentBalance: packed, outages: 0});
        emit HoldingMinted(tokenId, msg.sender, holdingType, balance, paidWithIMD);
    }

    /// @dev Pseudo-random, manipulable; see the contract-level note and README.
    function _random(uint256 tokenId) private view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    block.prevrandao,
                    blockhash(block.number - 1),
                    block.timestamp,
                    msg.sender,
                    tokenId,
                    address(this),
                    block.chainid
                )
            )
        );
    }

    function _typeName(HoldingType t) private pure returns (string memory) {
        if (t == HoldingType.ETH) return "ETH";
        if (t == HoldingType.IMD) return "IMD";
        return "CASH";
    }

    function _currency(HoldingType t) private pure returns (string memory) {
        if (t == HoldingType.ETH) return "ETH";
        if (t == HoldingType.IMD) return "IMD";
        return "USD";
    }

    function _description(HoldingType t) private pure returns (string memory) {
        if (t == HoldingType.CASH) {
            return "HOLDINGS: a conceptual balance held in cash. Anyone can cause an outage that lowers it; it can never rise again. Not actual funds.";
        }
        return
            "HOLDINGS: a conceptual balance held onchain. It is permanent and nothing can change it. Not actual funds.";
    }

    function _displayText(HoldingType t, uint256 balance) internal pure returns (string memory) {
        string memory amount = _withCommas(balance);
        if (t == HoldingType.CASH) return string.concat("$", amount);
        return string.concat(amount, " ", _currency(t));
    }

    function _svg(string memory text) internal pure returns (string memory) {
        uint256 fontSize = FONT_SCALE / bytes(text).length;
        if (fontSize > MAX_FONT_SIZE) fontSize = MAX_FONT_SIZE;
        string memory side = CANVAS.toString();
        string memory half = (CANVAS / 2).toString();
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ',
            side,
            " ",
            side,
            '" width="',
            side,
            '" height="',
            side,
            '"><rect width="',
            side,
            '" height="',
            side,
            '" fill="#ffffff"/><text x="',
            half,
            '" y="',
            half,
            '" fill="#000000" font-family="Courier New,Courier,monospace" font-weight="700" font-size="',
            fontSize.toString(),
            '" text-anchor="middle" dominant-baseline="central">',
            text,
            "</text></svg>"
        );
    }

    /// @dev Decimal with "," every three digits: 82194012 -> "82,194,012".
    function _withCommas(uint256 value) internal pure returns (string memory) {
        bytes memory digits = bytes(value.toString());
        uint256 len = digits.length;
        uint256 commas = (len - 1) / 3;
        bytes memory out = new bytes(len + commas);
        uint256 j = out.length;
        for (uint256 i = 0; i < len; ++i) {
            if (i > 0 && i % 3 == 0) out[--j] = ",";
            out[--j] = digits[len - 1 - i];
        }
        return string(out);
    }
}
