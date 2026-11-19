// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Holdings} from "../src/Holdings.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {WalletGas} from "./utils/WalletGas.sol";
import {OwnerContract} from "./utils/TestHelpers.sol";

/// @dev A smart-contract wallet: mints for itself, so `_safeMint` runs the receiver hook inside OZ's try/catch.
contract ContractWallet is IERC721Receiver {
    uint256 public received;

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        received += 1; // costs real gas inside the caught call
        return IERC721Receiver.onERC721Received.selector;
    }

    function mintEth(Holdings h) external payable returns (uint256) {
        return h.mint{value: msg.value}();
    }

    function approve(MockIMD token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function mintImd(Holdings h) external returns (uint256) {
        return h.mintWithIMD();
    }
}

/// @notice Every function a person or a bot sends, run at the least gas `eth_estimateGas` would return.
///         `mint`/`mintWithIMD` catch a failed receiver call (OZ `ERC721Utils` try/catch), SafeERC20 and
///         `withdrawETH` make low-level calls whose failure is inspected: none may succeed with its work skipped.
contract HoldingsWalletGasTest is WalletGas {
    address internal constant OWNER = address(0x0A11CE);
    address internal constant ALICE = address(0xA11CE5);
    address internal constant STRANGER = address(0x5757);
    uint256 internal constant ETH_PRICE = 0.00056 ether;
    uint256 internal constant IMD_PRICE = 0.35 ether;

    MockIMD internal imd;
    Holdings internal holdings;

    function setUp() public {
        imd = new MockIMD();
        holdings = new Holdings(OWNER, address(imd));
    }

    function _cashToken() internal returns (uint256 id) {
        vm.deal(ALICE, 1 ether);
        for (uint256 i; i < 64; i++) {
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("cash", i)))));
            vm.prank(ALICE);
            id = holdings.mint{value: ETH_PRICE}();
            (Holdings.HoldingType t,,,) = holdings.getHolding(id);
            if (t == Holdings.HoldingType.CASH) return id;
        }
        revert("no cash");
    }

    function test_walletGas_mintEthFromEOA() public {
        vm.deal(ALICE, ETH_PRICE);
        assertSameAtWalletGas(ALICE, address(holdings), ETH_PRICE, abi.encodeCall(Holdings.mint, ()));
    }

    function test_walletGas_mintEthFromContractWallet() public {
        ContractWallet w = new ContractWallet();
        vm.deal(ALICE, ETH_PRICE);
        assertSameAtWalletGas(ALICE, address(w), ETH_PRICE, abi.encodeCall(ContractWallet.mintEth, (holdings)));
    }

    function test_walletGas_mintEthLastToken() public {
        // Bring supply to 999 by minting, then check the 1,000th mint at a wallet's gas.
        vm.deal(ALICE, 1 ether);
        for (uint256 i; i < 999; i++) {
            vm.prank(ALICE);
            holdings.mint{value: ETH_PRICE}();
        }
        assertEq(holdings.totalSupply(), 999);
        assertSameAtWalletGas(ALICE, address(holdings), ETH_PRICE, abi.encodeCall(Holdings.mint, ()));
    }

    function test_walletGas_mintWithIMDFromEOA() public {
        imd.mint(ALICE, IMD_PRICE);
        vm.prank(ALICE);
        imd.approve(address(holdings), IMD_PRICE);
        assertSameAtWalletGas(ALICE, address(holdings), abi.encodeCall(Holdings.mintWithIMD, ()));
    }

    function test_walletGas_mintWithIMDFromContractWallet() public {
        ContractWallet w = new ContractWallet();
        imd.mint(address(w), IMD_PRICE);
        w.approve(imd, address(holdings), IMD_PRICE);
        assertSameAtWalletGas(ALICE, address(w), abi.encodeCall(ContractWallet.mintImd, (holdings)));
    }

    function test_walletGas_outage() public {
        uint256 id = _cashToken();
        assertSameAtWalletGas(STRANGER, address(holdings), abi.encodeCall(Holdings.outage, (id, 1)));
        assertSameAtWalletGas(STRANGER, address(holdings), abi.encodeCall(Holdings.outage, (id, 0)));
    }

    function test_walletGas_withdrawETHToEOA() public {
        _cashToken();
        assertSameAtWalletGas(OWNER, address(holdings), abi.encodeCall(Holdings.withdrawETH, ()));
    }

    function test_walletGas_withdrawETHToContractOwner() public {
        OwnerContract oc = new OwnerContract();
        oc.setHoldings(holdings);
        vm.prank(OWNER);
        holdings.transferOwnership(address(oc));
        oc.accept();
        _cashToken();
        assertSameAtWalletGas(address(oc), address(holdings), abi.encodeCall(Holdings.withdrawETH, ()));
    }

    function test_walletGas_withdrawIMD() public {
        imd.mint(ALICE, IMD_PRICE);
        vm.startPrank(ALICE);
        imd.approve(address(holdings), IMD_PRICE);
        holdings.mintWithIMD();
        vm.stopPrank();
        assertSameAtWalletGas(OWNER, address(holdings), abi.encodeCall(Holdings.withdrawIMD, ()));
    }
}
