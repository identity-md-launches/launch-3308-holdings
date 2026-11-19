// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Holdings} from "../../src/Holdings.sol";

/// @dev Exposes Holdings' internal renderers.
contract HoldingsHarness is Holdings {
    constructor(address owner_, address imd_) Holdings(owner_, imd_) {}

    function withCommas(uint256 v) external pure returns (string memory) {
        return _withCommas(v);
    }

    function display(HoldingType t, uint256 balance) external pure returns (string memory) {
        return _displayText(t, balance);
    }

    function svg(string memory text) external pure returns (string memory) {
        return _svg(text);
    }
}

/// @dev ERC-20 with configurable decimals.
contract DecimalsToken is ERC20 {
    uint8 private immutable _dec;

    constructor(uint8 dec) ERC20("Dec", "DEC") {
        _dec = dec;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burns 1% of every transfer, so the receiver gets less than the amount argument.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev Returns false from transferFrom instead of reverting.
contract FalseReturningToken is ERC20 {
    constructor() ERC20("False", "FLS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev Tries to mint again from inside the ERC-721 receiver hook.
contract ReentrantMinter is IERC721Receiver {
    Holdings public immutable holdings;
    bool public attempted;

    constructor(Holdings h) {
        holdings = h;
    }

    function go() external payable {
        holdings.mint{value: msg.value}();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (!attempted) {
            attempted = true;
            holdings.mint{value: address(this).balance}();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev A contract that accepts NFTs normally.
contract GoodReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function mintWithIMD(Holdings h) external returns (uint256) {
        return h.mintWithIMD();
    }

    function approve(ERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

/// @dev An owner contract that rejects ETH, or re-enters withdrawETH when it receives it.
contract OwnerContract {
    Holdings public holdings;
    bool public reenter;
    bool public reject;

    function setHoldings(Holdings h) external {
        holdings = h;
    }

    function setMode(bool reject_, bool reenter_) external {
        reject = reject_;
        reenter = reenter_;
    }

    function accept() external {
        holdings.acceptOwnership();
    }

    function withdraw() external {
        holdings.withdrawETH();
    }

    receive() external payable {
        if (reject) revert("no ETH");
        if (reenter) holdings.withdrawETH();
    }
}

/// @dev Minimal base64 decoder for inspecting tokenURI output.
library Base64Decode {
    function decode(string memory input) internal pure returns (bytes memory out) {
        bytes memory data = bytes(input);
        require(data.length % 4 == 0, "bad base64 length");
        uint256 pad;
        if (data.length > 0 && data[data.length - 1] == "=") pad++;
        if (data.length > 1 && data[data.length - 2] == "=") pad++;
        out = new bytes((data.length / 4) * 3 - pad);
        uint256 o;
        for (uint256 i = 0; i < data.length; i += 4) {
            uint256 n = (_val(data[i]) << 18) | (_val(data[i + 1]) << 12) | (_val(data[i + 2]) << 6) | _val(data[i + 3]);
            if (o < out.length) out[o++] = bytes1(uint8(n >> 16));
            if (o < out.length) out[o++] = bytes1(uint8(n >> 8));
            if (o < out.length) out[o++] = bytes1(uint8(n));
        }
    }

    function _val(bytes1 c) private pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65;
        if (x >= 97 && x <= 122) return x - 71;
        if (x >= 48 && x <= 57) return x + 4;
        if (x == 43) return 62;
        if (x == 47) return 63;
        if (x == 61) return 0;
        revert("bad base64 char");
    }

    /// @dev Strips a known prefix and returns the rest.
    function after_(string memory s, string memory prefix) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory p = bytes(prefix);
        require(b.length >= p.length, "short");
        for (uint256 i = 0; i < p.length; i++) {
            require(b[i] == p[i], "prefix mismatch");
        }
        bytes memory rest = new bytes(b.length - p.length);
        for (uint256 i = 0; i < rest.length; i++) {
            rest[i] = b[i + p.length];
        }
        return string(rest);
    }
}
