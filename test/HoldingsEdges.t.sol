// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Holdings} from "../src/Holdings.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {Base64Decode} from "./utils/TestHelpers.sol";

/// @dev Mints, and reverts the whole transaction unless the outcome is an ETH holding. Shows the documented
///      pseudo-randomness risk: a contract minter only ever keeps the outcomes it likes.
contract PickyMinter is IERC721Receiver {
    Holdings public immutable h;

    constructor(Holdings h_) {
        h = h_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function mintOnlyEth() external payable returns (uint256 id) {
        id = h.mint{value: msg.value}();
        (Holdings.HoldingType t,,,) = h.getHolding(id);
        require(t == Holdings.HoldingType.ETH, "reroll");
    }
}

contract HoldingsEdgesTest is Test {
    address internal constant OWNER = address(0x0A11CE);
    address internal constant ALICE = address(0xA11CE5);
    address internal constant BOB = address(0xB0B);
    address internal constant STRANGER = address(0x5757);
    uint256 internal constant ETH_PRICE = 0.00056 ether;
    uint256 internal constant IMD_PRICE = 0.35 ether;

    MockIMD internal imd;
    Holdings internal holdings;

    function setUp() public {
        imd = new MockIMD();
        holdings = new Holdings(OWNER, address(imd));
    }

    function _mintEth(address who) internal returns (uint256 id) {
        vm.deal(who, ETH_PRICE);
        vm.prank(who);
        id = holdings.mint{value: ETH_PRICE}();
    }

    function _mintImd(address who) internal returns (uint256 id) {
        imd.mint(who, IMD_PRICE);
        vm.startPrank(who);
        imd.approve(address(holdings), IMD_PRICE);
        id = holdings.mintWithIMD();
        vm.stopPrank();
    }

    function _type(uint256 id) internal view returns (Holdings.HoldingType t) {
        (t,,,) = holdings.getHolding(id);
    }

    function _mintOfType(Holdings.HoldingType want) internal returns (uint256 id) {
        for (uint256 i; i < 64; i++) {
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("edge", i, holdings.totalSupply())))));
            id = _mintEth(ALICE);
            if (_type(id) == want) return id;
        }
        revert("none");
    }

    function _json(uint256 id) internal view returns (string memory) {
        return string(Base64Decode.decode(Base64Decode.after_(holdings.tokenURI(id), "data:application/json;base64,")));
    }

    // ---------------------------------------------------------------- outage edges

    function test_outageExactlyOneBelowSucceedsEqualFails() public {
        uint256 id = _mintOfType(Holdings.HoldingType.CASH);
        (, uint256 orig,,) = holdings.getHolding(id);
        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, orig, orig));
        holdings.outage(id, orig);
        vm.prank(STRANGER);
        holdings.outage(id, orig - 1);
        (,, uint256 cur,) = holdings.getHolding(id);
        assertEq(cur, orig - 1);
    }

    function test_outageWithMaxUintReverts() public {
        uint256 id = _mintOfType(Holdings.HoldingType.CASH);
        (, uint256 orig,,) = holdings.getHolding(id);
        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, orig, type(uint256).max));
        holdings.outage(id, type(uint256).max);
    }

    function test_outageAtZeroCannotRepeat() public {
        uint256 id = _mintOfType(Holdings.HoldingType.CASH);
        holdings.outage(id, 0);
        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, 0, 0));
        holdings.outage(id, 0);
        assertEq(holdings.outageCount(id), 1);
        (, uint256 orig,,) = holdings.getHolding(id);
        assertGt(orig, 0, "original preserved after reaching zero");
    }

    function test_outageOnTokenZeroAndPastSupplyReverts() public {
        _mintEth(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        holdings.outage(0, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        holdings.outage(2, 0);
    }

    function test_outageIsNotPayable() public {
        uint256 id = _mintOfType(Holdings.HoldingType.CASH);
        vm.deal(STRANGER, 1 ether);
        vm.prank(STRANGER);
        (bool ok,) = address(holdings).call{value: 1}(abi.encodeCall(Holdings.outage, (id, 0)));
        assertFalse(ok);
    }

    function testFuzz_outageOnNonCashAlwaysReverts(uint256 newBalance, bool imdHolding) public {
        uint256 id = imdHolding ? _mintImd(ALICE) : _mintOfType(Holdings.HoldingType.ETH);
        Holdings.HoldingType t = _type(id);
        vm.expectRevert(abi.encodeWithSelector(Holdings.NotCashHolding.selector, id, t));
        vm.prank(OWNER);
        holdings.outage(id, newBalance);
    }

    function testFuzz_outageByOwnerOrHolderCannotRaise(uint256 lowered, uint256 raised) public {
        uint256 id = _mintOfType(Holdings.HoldingType.CASH);
        (, uint256 orig,,) = holdings.getHolding(id);
        lowered = bound(lowered, 0, orig - 1);
        vm.prank(ALICE); // the holder
        holdings.outage(id, lowered);
        raised = bound(raised, lowered, type(uint256).max);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, lowered, raised));
        holdings.outage(id, raised);
    }

    function test_metadataAfterTransferAndOutage() public {
        uint256 id = _mintOfType(Holdings.HoldingType.CASH);
        vm.prank(ALICE);
        holdings.transferFrom(ALICE, BOB, id);
        holdings.outage(id, 1_000);
        string memory json = _json(id);
        assertEq(vm.parseJsonString(json, ".holding_type"), "CASH");
        assertEq(vm.parseJsonString(json, ".currency"), "USD");
        assertEq(vm.parseJsonUint(json, ".current_balance"), 1_000);
        assertEq(vm.parseJsonString(json, ".display"), "$1,000");
        (, uint256 orig,,) = holdings.getHolding(id);
        assertEq(vm.parseJsonUint(json, ".initial_balance"), orig);
    }

    // ---------------------------------------------------------------- minting edges

    function test_wrongEthAtSoldOutStillReverts() public {
        vm.deal(ALICE, 1 ether);
        for (uint256 i; i < 1_000; i++) {
            vm.prank(ALICE);
            holdings.mint{value: ETH_PRICE}();
        }
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IncorrectETHPayment.selector, ETH_PRICE + 1, ETH_PRICE));
        holdings.mint{value: ETH_PRICE + 1}();
        vm.prank(ALICE);
        vm.expectRevert(Holdings.SoldOut.selector);
        holdings.mint{value: ETH_PRICE}();
        imd.mint(ALICE, IMD_PRICE);
        vm.startPrank(ALICE);
        imd.approve(address(holdings), IMD_PRICE);
        vm.expectRevert(Holdings.SoldOut.selector);
        holdings.mintWithIMD();
        vm.stopPrank();
        assertEq(imd.balanceOf(ALICE), IMD_PRICE, "no IMD taken on a sold-out mint");
        assertEq(holdings.totalSupply(), 1_000);
        assertEq(address(holdings).balance, 1_000 * ETH_PRICE);
    }

    function test_imdMintTakesOnlyPriceFromLargerAllowance() public {
        imd.mint(ALICE, 5 ether);
        vm.startPrank(ALICE);
        imd.approve(address(holdings), type(uint256).max);
        holdings.mintWithIMD();
        holdings.mintWithIMD();
        vm.stopPrank();
        assertEq(imd.balanceOf(ALICE), 5 ether - 2 * IMD_PRICE);
        assertEq(imd.balanceOf(address(holdings)), 2 * IMD_PRICE);
    }

    function test_imdAllowanceOneWeiShortReverts() public {
        imd.mint(ALICE, IMD_PRICE);
        vm.startPrank(ALICE);
        imd.approve(address(holdings), IMD_PRICE - 1);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IMDAllowanceTooLow.selector, IMD_PRICE - 1, IMD_PRICE));
        holdings.mintWithIMD();
        vm.stopPrank();
    }

    function test_imdBalanceOneWeiShortReverts() public {
        imd.mint(ALICE, IMD_PRICE - 1);
        vm.startPrank(ALICE);
        imd.approve(address(holdings), IMD_PRICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IMDBalanceTooLow.selector, IMD_PRICE - 1, IMD_PRICE));
        holdings.mintWithIMD();
        vm.stopPrank();
    }

    function test_ethMintSendsNoIMDAndImdMintTakesNoETH() public {
        _mintEth(ALICE);
        assertEq(imd.balanceOf(address(holdings)), 0);
        _mintImd(BOB);
        assertEq(address(holdings).balance, ETH_PRICE);
    }

    /// @dev 600 ETH mints from varied minters, blocks and randao: share of ETH holdings within 6 sigma of 50%.
    function test_ethCashSplitAcrossManyMinters() public {
        uint256 ethCount;
        for (uint256 i; i < 600; i++) {
            address who = address(uint160(uint256(keccak256(abi.encode("minter", i)))));
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            vm.prevrandao(keccak256(abi.encode("randao", i)));
            uint256 id = _mintEth(who);
            Holdings.HoldingType t = _type(id);
            assertTrue(t != Holdings.HoldingType.IMD);
            if (t == Holdings.HoldingType.ETH) ethCount++;
        }
        // n=600, sigma ~= 12.2: [227, 373]
        assertGe(ethCount, 227);
        assertLe(ethCount, 373);
    }

    /// @dev Documented risk, not an endorsed behaviour: see README "Randomness and its manipulation risks".
    ///      A contract minter that reverts on outcomes it dislikes keeps only ETH holdings.
    function test_documentedRisk_contractMinterCanDiscardOutcomes() public {
        PickyMinter p = new PickyMinter(holdings);
        vm.deal(address(this), 1 ether);
        uint256 kept;
        for (uint256 i; i < 20; i++) {
            vm.prevrandao(keccak256(abi.encode("picky", i)));
            try p.mintOnlyEth{value: ETH_PRICE}() returns (uint256 id) {
                assertTrue(_type(id) == Holdings.HoldingType.ETH);
                kept++;
            } catch {}
        }
        assertEq(holdings.balanceOf(address(p)), kept);
        assertGt(kept, 0);
        assertLt(kept, 20);
    }

    // ---------------------------------------------------------------- owner edges

    function test_newOwnerWithdrawsOldOwnerCannot() public {
        _mintEth(ALICE);
        _mintImd(ALICE);
        vm.prank(OWNER);
        holdings.transferOwnership(BOB);
        vm.prank(BOB);
        holdings.acceptOwnership();

        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        holdings.withdrawETH();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        holdings.withdrawIMD();
        vm.stopPrank();

        uint256 before = BOB.balance;
        vm.startPrank(BOB);
        holdings.withdrawETH();
        holdings.withdrawIMD();
        vm.stopPrank();
        assertEq(BOB.balance - before, ETH_PRICE);
        assertEq(imd.balanceOf(BOB), IMD_PRICE);
        assertEq(address(holdings).balance, 0);
        assertEq(imd.balanceOf(address(holdings)), 0);
    }

    function test_withdrawIncludesForcedAndDonatedFunds() public {
        vm.deal(address(holdings), 3 ether); // forced ETH, e.g. selfdestruct
        imd.mint(address(holdings), 7 ether);
        uint256 before = OWNER.balance;
        vm.startPrank(OWNER);
        holdings.withdrawETH();
        holdings.withdrawIMD();
        vm.stopPrank();
        assertEq(OWNER.balance - before, 3 ether);
        assertEq(imd.balanceOf(OWNER), 7 ether);
    }

    function test_withdrawTwiceSecondReverts() public {
        _mintEth(ALICE);
        vm.startPrank(OWNER);
        holdings.withdrawETH();
        vm.expectRevert(Holdings.NothingToWithdraw.selector);
        holdings.withdrawETH();
        vm.stopPrank();
    }

    function test_ownerHasNoPathToBalancesOrMetadata() public view {
        // No setter exists: the only state-changing selectors besides ERC-721 and Ownable2Step are mints, outage
        // and withdrawals. Probe a few plausible admin selectors: all must hit no function.
        bytes4[5] memory probes = [
            bytes4(keccak256("setBaseURI(string)")),
            bytes4(keccak256("setBalance(uint256,uint256)")),
            bytes4(keccak256("setHoldingType(uint256,uint8)")),
            bytes4(keccak256("setIMD(address)")),
            bytes4(keccak256("upgradeTo(address)"))
        ];
        for (uint256 i; i < probes.length; i++) {
            (bool ok,) = address(holdings).staticcall(abi.encodePacked(probes[i], uint256(1), uint256(2)));
            assertFalse(ok);
        }
    }

    function test_tokenURIAndViewsRevertForMissingToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        holdings.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        holdings.tokenSVG(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        holdings.outageCount(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        holdings.displayText(1);
    }
}
