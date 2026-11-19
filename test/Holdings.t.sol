// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Holdings} from "../src/Holdings.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {
    HoldingsHarness,
    DecimalsToken,
    FeeOnTransferToken,
    FalseReturningToken,
    ReentrantMinter,
    GoodReceiver,
    OwnerContract,
    Base64Decode
} from "./utils/TestHelpers.sol";

contract HoldingsTestBase is Test {
    event Outage(uint256 indexed tokenId, uint256 previousBalance, uint256 newBalance, address indexed caller);
    event MetadataUpdate(uint256 _tokenId);
    event HoldingMinted(
        uint256 indexed tokenId,
        address indexed minter,
        Holdings.HoldingType holdingType,
        uint256 balance,
        bool paidWithIMD
    );

    address internal constant OWNER = address(0x0A11CE);
    address internal constant ALICE = address(0xA11CE5);
    address internal constant BOB = address(0xB0B);
    address internal constant STRANGER = address(0x5757);

    uint256 internal constant ETH_PRICE = 0.00056 ether;
    uint256 internal constant IMD_PRICE = 0.35 ether; // 0.35 IMD at 18 decimals

    MockIMD internal imd;
    Holdings internal holdings;

    function setUp() public virtual {
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
        vm.prank(who);
        imd.approve(address(holdings), IMD_PRICE);
        vm.prank(who);
        id = holdings.mintWithIMD();
    }

    function _type(uint256 id) internal view returns (Holdings.HoldingType t) {
        (t,,,) = holdings.getHolding(id);
    }

    function _balances(uint256 id) internal view returns (uint256 original, uint256 current) {
        (, original, current,) = holdings.getHolding(id);
    }

    /// @dev Mints with ETH (varying prevrandao) until a holding of `want` appears.
    function _mintEthOfType(Holdings.HoldingType want) internal returns (uint256 id) {
        for (uint256 i = 0; i < 64; i++) {
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("seed", i, holdings.totalSupply())))));
            id = _mintEth(ALICE);
            if (_type(id) == want) return id;
        }
        revert("no holding of requested type");
    }

    function _decodeJson(uint256 id) internal view returns (string memory) {
        string memory b64 = Base64Decode.after_(holdings.tokenURI(id), "data:application/json;base64,");
        return string(Base64Decode.decode(b64));
    }

    function _decodeImage(string memory json) internal pure returns (string memory) {
        string memory image = vm.parseJsonString(json, ".image");
        return string(Base64Decode.decode(Base64Decode.after_(image, "data:image/svg+xml;base64,")));
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        return vm.indexOf(hay, needle) != type(uint256).max;
    }
}

contract HoldingsDeploymentTest is HoldingsTestBase {
    function test_constructorSetsConfiguration() public view {
        assertEq(holdings.name(), "HOLDINGS");
        assertEq(holdings.symbol(), "HODL");
        assertEq(holdings.owner(), OWNER);
        assertEq(address(holdings.IMD()), address(imd));
        assertEq(holdings.totalSupply(), 0);
        assertEq(holdings.MAX_SUPPLY(), 1000);
        assertEq(holdings.ETH_PRICE(), ETH_PRICE);
        assertEq(holdings.imdPrice(), IMD_PRICE);
    }

    function test_constructorRejectsZeroIMD() public {
        vm.expectRevert(Holdings.ZeroIMDToken.selector);
        new Holdings(OWNER, address(0));
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Holdings(address(0), address(imd));
    }

    function test_constructorDoesNotCallTheToken() public {
        // An address with no code: the constructor must still succeed (launch checks run on an empty chain).
        Holdings h = new Holdings(OWNER, address(0xDEAD0001));
        assertEq(address(h.IMD()), address(0xDEAD0001));
        // ...and the token is only checked on first use.
        vm.expectRevert();
        h.mintWithIMD();
    }

    function test_ownerIsNotDeployer() public view {
        assertTrue(holdings.owner() != address(this));
    }

    function test_supportsInterfaces() public view {
        assertTrue(holdings.supportsInterface(0x49064906)); // ERC-4906
        assertTrue(holdings.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(holdings.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(holdings.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(holdings.supportsInterface(0xffffffff));
    }
}

contract HoldingsEthMintTest is HoldingsTestBase {
    function test_mintWithExactEth() public {
        vm.deal(ALICE, ETH_PRICE);
        vm.prank(ALICE);
        uint256 id = holdings.mint{value: ETH_PRICE}();
        assertEq(id, 1);
        assertEq(holdings.ownerOf(1), ALICE);
        assertEq(holdings.totalSupply(), 1);
        assertEq(address(holdings).balance, ETH_PRICE);
        Holdings.HoldingType t = _type(id);
        assertTrue(t == Holdings.HoldingType.ETH || t == Holdings.HoldingType.CASH);
        (uint256 original, uint256 current) = _balances(id);
        assertEq(original, current);
        assertGe(original, 1);
        assertLe(original, 1_000_000_000);
    }

    function test_mintEmitsHoldingMinted() public {
        vm.deal(ALICE, ETH_PRICE);
        vm.recordLogs();
        vm.prank(ALICE);
        uint256 id = holdings.mint{value: ETH_PRICE}();
        (Holdings.HoldingType t, uint256 original,,) = holdings.getHolding(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == HoldingMinted.selector) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), id);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), ALICE);
                (Holdings.HoldingType lt, uint256 lb, bool paidWithIMD) =
                    abi.decode(logs[i].data, (Holdings.HoldingType, uint256, bool));
                assertTrue(lt == t);
                assertEq(lb, original);
                assertFalse(paidWithIMD);
            }
        }
        assertTrue(found);
    }

    function test_mintRejectsTooLittleEth() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IncorrectETHPayment.selector, ETH_PRICE - 1, ETH_PRICE));
        holdings.mint{value: ETH_PRICE - 1}();
    }

    function test_mintRejectsTooMuchEth() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IncorrectETHPayment.selector, ETH_PRICE + 1, ETH_PRICE));
        holdings.mint{value: ETH_PRICE + 1}();
    }

    function test_mintRejectsZeroEth() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IncorrectETHPayment.selector, 0, ETH_PRICE));
        holdings.mint();
    }

    function testFuzz_mintRejectsAnyWrongAmount(uint256 value) public {
        value = bound(value, 0, 100 ether);
        vm.assume(value != ETH_PRICE);
        vm.deal(ALICE, value);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IncorrectETHPayment.selector, value, ETH_PRICE));
        holdings.mint{value: value}();
        assertEq(holdings.totalSupply(), 0);
    }

    function test_plainEthTransferRejected() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(holdings).call{value: ETH_PRICE}("");
        assertFalse(ok);
    }

    function test_ethMintsAreRoughlyHalfEthHalfCash() public {
        uint256 ethCount;
        uint256 cashCount;
        for (uint256 i = 0; i < 1000; i++) {
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode(i)))));
            address minter = address(uint160(0x10000 + i));
            uint256 id = _mintEth(minter);
            Holdings.HoldingType t = _type(id);
            (uint256 original, uint256 current) = _balances(id);
            assertGe(original, 1);
            assertLe(original, 1_000_000_000);
            assertEq(original, current);
            if (t == Holdings.HoldingType.ETH) ethCount++;
            else if (t == Holdings.HoldingType.CASH) cashCount++;
            else revert("ETH mint produced IMD");
        }
        assertEq(ethCount + cashCount, 1000);
        // Binomial(1000, 0.5): sd ~15.8; 450..550 is more than 3 sd either side.
        assertGe(ethCount, 450, "too few ETH holdings");
        assertGe(cashCount, 450, "too few CASH holdings");
    }

    function testFuzz_balanceAlwaysInRange(bytes32 randao, address minter, uint256 blockNumber) public {
        vm.assume(minter != address(0) && minter.code.length == 0 && uint160(minter) > 0x100);
        vm.roll(bound(blockNumber, 1, type(uint64).max));
        vm.prevrandao(randao);
        uint256 id = _mintEth(minter);
        (uint256 original, uint256 current) = _balances(id);
        assertGe(original, 1);
        assertLe(original, 1_000_000_000);
        assertEq(current, original);
    }

    function test_mintToContractReceiver() public {
        GoodReceiver r = new GoodReceiver();
        vm.deal(address(r), ETH_PRICE);
        vm.prank(address(r));
        uint256 id = holdings.mint{value: ETH_PRICE}();
        assertEq(holdings.ownerOf(id), address(r));
    }

    function test_mintToNonReceiverContractReverts() public {
        // MockIMD does not implement onERC721Received.
        vm.deal(address(imd), ETH_PRICE);
        vm.prank(address(imd));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(imd)));
        holdings.mint{value: ETH_PRICE}();
        assertEq(holdings.totalSupply(), 0);
    }

    function test_reentrantMintFromReceiverReverts() public {
        ReentrantMinter r = new ReentrantMinter(holdings);
        vm.deal(address(this), 2 * ETH_PRICE);
        payable(address(r)).transfer(ETH_PRICE);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        r.go{value: ETH_PRICE}();
        assertEq(holdings.totalSupply(), 0);
        assertEq(address(holdings).balance, 0);
    }
}

contract HoldingsImdMintTest is HoldingsTestBase {
    function test_mintWithIMDTransfersExactlyPrice() public {
        imd.mint(ALICE, 1 ether);
        vm.prank(ALICE);
        imd.approve(address(holdings), type(uint256).max);
        vm.prank(ALICE);
        uint256 id = holdings.mintWithIMD();
        assertEq(holdings.ownerOf(id), ALICE);
        assertEq(imd.balanceOf(address(holdings)), IMD_PRICE);
        assertEq(imd.balanceOf(ALICE), 1 ether - IMD_PRICE);
        assertEq(address(holdings).balance, 0);
        (Holdings.HoldingType t, uint256 original, uint256 current, string memory currency) = holdings.getHolding(id);
        assertTrue(t == Holdings.HoldingType.IMD);
        assertEq(currency, "IMD");
        assertEq(original, current);
    }

    function test_imdMintsAlwaysProduceIMD() public {
        for (uint256 i = 0; i < 300; i++) {
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode("imd", i)))));
            uint256 id = _mintImd(address(uint160(0x20000 + i)));
            (Holdings.HoldingType t, uint256 original, uint256 current,) = holdings.getHolding(id);
            assertTrue(t == Holdings.HoldingType.IMD);
            assertGe(original, 1);
            assertLe(original, 1_000_000_000);
            assertEq(current, original);
        }
        assertEq(imd.balanceOf(address(holdings)), 300 * IMD_PRICE);
    }

    function test_mintWithIMDRequiresApproval() public {
        imd.mint(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IMDAllowanceTooLow.selector, 0, IMD_PRICE));
        holdings.mintWithIMD();
    }

    function test_mintWithIMDRejectsInsufficientAllowance() public {
        imd.mint(ALICE, 1 ether);
        vm.prank(ALICE);
        imd.approve(address(holdings), IMD_PRICE - 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IMDAllowanceTooLow.selector, IMD_PRICE - 1, IMD_PRICE));
        holdings.mintWithIMD();
    }

    function test_mintWithIMDRejectsInsufficientBalance() public {
        imd.mint(ALICE, IMD_PRICE - 1);
        vm.prank(ALICE);
        imd.approve(address(holdings), IMD_PRICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IMDBalanceTooLow.selector, IMD_PRICE - 1, IMD_PRICE));
        holdings.mintWithIMD();
        assertEq(holdings.totalSupply(), 0);
    }

    function test_mintWithIMDIsNotPayable() public {
        imd.mint(ALICE, 1 ether);
        vm.prank(ALICE);
        imd.approve(address(holdings), IMD_PRICE);
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(holdings).call{value: ETH_PRICE}(abi.encodeCall(Holdings.mintWithIMD, ()));
        assertFalse(ok);
        assertEq(holdings.totalSupply(), 0);
    }

    function test_onlyConfiguredTokenIsAccepted() public {
        // Paying with another ERC-20 is impossible: the only IMD pull is from the immutable IMD address.
        DecimalsToken other = new DecimalsToken(18);
        other.mint(ALICE, 1 ether);
        vm.prank(ALICE);
        other.approve(address(holdings), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.IMDAllowanceTooLow.selector, 0, IMD_PRICE));
        holdings.mintWithIMD();
        assertEq(other.balanceOf(ALICE), 1 ether);
    }

    function test_priceScalesWithDecimals() public {
        DecimalsToken six = new DecimalsToken(6);
        Holdings h = new Holdings(OWNER, address(six));
        assertEq(h.imdPrice(), 350_000);
        six.mint(ALICE, 350_000);
        vm.prank(ALICE);
        six.approve(address(h), 350_000);
        vm.prank(ALICE);
        h.mintWithIMD();
        assertEq(six.balanceOf(address(h)), 350_000);
        assertEq(six.balanceOf(ALICE), 0);

        DecimalsToken two = new DecimalsToken(2);
        assertEq(new Holdings(OWNER, address(two)).imdPrice(), 35);
    }

    function test_tooFewDecimalsRejected() public {
        DecimalsToken one = new DecimalsToken(1);
        Holdings h = new Holdings(OWNER, address(one));
        vm.expectRevert(abi.encodeWithSelector(Holdings.UnsupportedIMDDecimals.selector, uint8(1)));
        h.imdPrice();
        vm.expectRevert(abi.encodeWithSelector(Holdings.UnsupportedIMDDecimals.selector, uint8(1)));
        h.mintWithIMD();
    }

    function test_feeOnTransferPaymentRejected() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        Holdings h = new Holdings(OWNER, address(fee));
        fee.mint(ALICE, 1 ether);
        vm.prank(ALICE);
        fee.approve(address(h), IMD_PRICE);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(Holdings.IMDPaymentShort.selector, IMD_PRICE - IMD_PRICE / 100, IMD_PRICE)
        );
        h.mintWithIMD();
        assertEq(h.totalSupply(), 0);
    }

    function test_falseReturningTokenRejectedBySafeERC20() public {
        FalseReturningToken f = new FalseReturningToken();
        Holdings h = new Holdings(OWNER, address(f));
        f.mint(ALICE, 1 ether);
        vm.prank(ALICE);
        f.approve(address(h), IMD_PRICE);
        vm.prank(ALICE);
        vm.expectRevert();
        h.mintWithIMD();
        assertEq(h.totalSupply(), 0);
    }

    function test_contractCanMintWithIMD() public {
        GoodReceiver r = new GoodReceiver();
        imd.mint(address(r), IMD_PRICE);
        r.approve(imd, address(holdings), IMD_PRICE);
        uint256 id = r.mintWithIMD(holdings);
        assertEq(holdings.ownerOf(id), address(r));
    }
}

contract HoldingsSupplyTest is HoldingsTestBase {
    function test_supplyCapAcrossBothPaymentMethods() public {
        for (uint256 i = 0; i < 600; i++) {
            _mintEth(address(uint160(0x30000 + i)));
        }
        for (uint256 i = 0; i < 400; i++) {
            _mintImd(address(uint160(0x40000 + i)));
        }
        assertEq(holdings.totalSupply(), 1000);
        assertEq(holdings.ownerOf(1000), address(uint160(0x40000 + 399)));

        vm.deal(BOB, ETH_PRICE);
        vm.prank(BOB);
        vm.expectRevert(Holdings.SoldOut.selector);
        holdings.mint{value: ETH_PRICE}();

        imd.mint(BOB, IMD_PRICE);
        vm.prank(BOB);
        imd.approve(address(holdings), IMD_PRICE);
        vm.prank(BOB);
        vm.expectRevert(Holdings.SoldOut.selector);
        holdings.mintWithIMD();

        assertEq(holdings.totalSupply(), 1000);
        assertEq(imd.balanceOf(BOB), IMD_PRICE);
        assertEq(address(holdings).balance, 600 * ETH_PRICE);
        assertEq(imd.balanceOf(address(holdings)), 400 * IMD_PRICE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1001));
        holdings.ownerOf(1001);
    }

    function test_supplyCapWithImdOnly() public {
        for (uint256 i = 0; i < 1000; i++) {
            _mintImd(address(uint160(0x50000 + i)));
        }
        imd.mint(BOB, IMD_PRICE);
        vm.prank(BOB);
        imd.approve(address(holdings), IMD_PRICE);
        vm.prank(BOB);
        vm.expectRevert(Holdings.SoldOut.selector);
        holdings.mintWithIMD();
    }
}

contract HoldingsOutageTest is HoldingsTestBase {
    function test_anyoneCanCauseOutage() public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.CASH);
        (uint256 original, uint256 current) = _balances(id);
        uint256 target = current / 2;

        vm.expectEmit(true, true, false, true, address(holdings));
        emit Outage(id, current, target, STRANGER);
        vm.expectEmit(false, false, false, true, address(holdings));
        emit MetadataUpdate(id);
        vm.prank(STRANGER); // neither the token holder nor the contract owner
        holdings.outage(id, target);

        (uint256 o2, uint256 c2) = _balances(id);
        assertEq(o2, original, "original must be preserved");
        assertEq(c2, target);
        assertEq(holdings.outageCount(id), 1);
        assertEq(holdings.ownerOf(id), ALICE);
    }

    function test_outageCanReachZeroAndThenNothingMore() public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.CASH);
        (uint256 original,) = _balances(id);
        vm.prank(BOB);
        holdings.outage(id, 0);
        (uint256 o, uint256 c) = _balances(id);
        assertEq(c, 0);
        assertEq(o, original);
        assertEq(holdings.displayText(id), "$0");

        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, 0, 0));
        holdings.outage(id, 0);
        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, 0, 1));
        holdings.outage(id, 1);
    }

    function test_outageCannotIncreaseOrKeepBalance() public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.CASH);
        (, uint256 current) = _balances(id);
        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, current, current));
        holdings.outage(id, current);
        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, current, current + 1));
        holdings.outage(id, current + 1);
        vm.expectRevert(
            abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, current, uint256(type(uint256).max))
        );
        holdings.outage(id, type(uint256).max);
    }

    function test_ownerCannotRestoreCashBalance() public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.CASH);
        (uint256 original, uint256 current) = _balances(id);
        holdings.outage(id, current - 1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, current - 1, original));
        holdings.outage(id, original);
        vm.prank(ALICE); // the token holder cannot either
        vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, current - 1, current));
        holdings.outage(id, current);
    }

    function test_outageOnEthHoldingReverts() public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.ETH);
        vm.expectRevert(abi.encodeWithSelector(Holdings.NotCashHolding.selector, id, Holdings.HoldingType.ETH));
        holdings.outage(id, 0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Holdings.NotCashHolding.selector, id, Holdings.HoldingType.ETH));
        holdings.outage(id, 1);
    }

    function test_outageOnImdHoldingReverts() public {
        uint256 id = _mintImd(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Holdings.NotCashHolding.selector, id, Holdings.HoldingType.IMD));
        holdings.outage(id, 0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Holdings.NotCashHolding.selector, id, Holdings.HoldingType.IMD));
        holdings.outage(id, 1);
    }

    function test_outageOnNonexistentTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 7));
        holdings.outage(7, 0);
    }

    function testFuzz_outageSequenceNeverIncreases(uint256 a, uint256 b, uint256 c) public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.CASH);
        uint256[3] memory attempts = [a, b, c];
        (uint256 original,) = _balances(id);
        uint256 last = original;
        for (uint256 i = 0; i < 3; i++) {
            uint256 want = bound(attempts[i], 0, 2 * original);
            if (want < last) {
                holdings.outage(id, want);
                last = want;
            } else {
                vm.expectRevert(abi.encodeWithSelector(Holdings.BalanceMustDecrease.selector, last, want));
                holdings.outage(id, want);
            }
            (uint256 o, uint256 cur) = _balances(id);
            assertEq(o, original);
            assertEq(cur, last);
            assertLe(cur, original);
        }
    }

    function test_manySuccessiveOutages() public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.CASH);
        (, uint256 current) = _balances(id);
        uint256 n;
        while (current > 0 && n < 40) {
            uint256 next = current / 3;
            vm.prank(address(uint160(0x60000 + n)));
            holdings.outage(id, next);
            (, uint256 c2) = _balances(id);
            assertLt(c2, current);
            current = c2;
            n++;
        }
        assertEq(current, 0);
        assertEq(holdings.outageCount(id), n);
    }
}

contract HoldingsImmutabilityTest is HoldingsTestBase {
    struct Snapshot {
        Holdings.HoldingType holdingType;
        uint256 original;
        uint256 current;
        string currency;
        string uri;
    }

    function _snap(uint256 id) internal view returns (Snapshot memory s) {
        (s.holdingType, s.original, s.current, s.currency) = holdings.getHolding(id);
        s.uri = holdings.tokenURI(id);
    }

    function _assertSame(Snapshot memory a, Snapshot memory b) internal pure {
        assertTrue(a.holdingType == b.holdingType);
        assertEq(a.original, b.original);
        assertEq(a.current, b.current);
        assertEq(a.original, a.current);
        assertEq(a.currency, b.currency);
        assertEq(a.uri, b.uri);
    }

    function test_ethAndImdBalancesNeverChange() public {
        uint256 ethId = _mintEthOfType(Holdings.HoldingType.ETH);
        uint256 cashId = _mintEthOfType(Holdings.HoldingType.CASH);
        uint256 imdId = _mintImd(BOB);
        Snapshot memory ethBefore = _snap(ethId);
        Snapshot memory imdBefore = _snap(imdId);
        assertTrue(ethBefore.holdingType == Holdings.HoldingType.ETH);
        assertTrue(imdBefore.holdingType == Holdings.HoldingType.IMD);

        // Everything anyone can do: outages (rejected), outages on other tokens, transfers, more mints, withdrawals,
        // ownership transfer.
        vm.prank(OWNER);
        vm.expectRevert();
        holdings.outage(ethId, 0);
        vm.prank(OWNER);
        vm.expectRevert();
        holdings.outage(imdId, 0);
        holdings.outage(cashId, 0);
        vm.prank(ALICE);
        holdings.transferFrom(ALICE, STRANGER, ethId);
        vm.prank(BOB);
        holdings.safeTransferFrom(BOB, STRANGER, imdId);
        _mintEth(ALICE);
        _mintImd(ALICE);
        vm.startPrank(OWNER);
        holdings.withdrawETH();
        holdings.withdrawIMD();
        holdings.transferOwnership(BOB);
        vm.stopPrank();
        vm.prank(BOB);
        holdings.acceptOwnership();

        _assertSame(ethBefore, _snap(ethId));
        _assertSame(imdBefore, _snap(imdId));
        assertEq(holdings.outageCount(ethId), 0);
        assertEq(holdings.outageCount(imdId), 0);
    }

    function test_cashHoldingTypeSurvivesTransferAndZero() public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.CASH);
        holdings.outage(id, 0);
        vm.prank(ALICE);
        holdings.transferFrom(ALICE, BOB, id);
        (Holdings.HoldingType t, uint256 o, uint256 c, string memory cur) = holdings.getHolding(id);
        assertTrue(t == Holdings.HoldingType.CASH);
        assertGt(o, 0);
        assertEq(c, 0);
        assertEq(cur, "USD");
    }

    function test_getHoldingRevertsForNonexistentToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        holdings.getHolding(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        holdings.tokenURI(1);
    }
}

contract HoldingsMetadataTest is HoldingsTestBase {
    function test_cashMetadataAndSvgUpdateAfterOutage() public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.CASH);
        (uint256 original,) = _balances(id);
        string memory uriBefore = holdings.tokenURI(id);
        string memory svgBefore = holdings.tokenSVG(id);

        vm.prank(STRANGER);
        holdings.outage(id, 82_194_012 < original ? 82_194_012 : original - 1);
        (, uint256 current) = _balances(id);

        string memory uriAfter = holdings.tokenURI(id);
        string memory svgAfter = holdings.tokenSVG(id);
        assertTrue(keccak256(bytes(uriBefore)) != keccak256(bytes(uriAfter)), "tokenURI unchanged");
        assertTrue(keccak256(bytes(svgBefore)) != keccak256(bytes(svgAfter)), "SVG unchanged");

        string memory json = _decodeJson(id);
        assertEq(vm.parseJsonString(json, ".holding_type"), "CASH");
        assertEq(vm.parseJsonString(json, ".currency"), "USD");
        assertEq(vm.parseJsonUint(json, ".initial_balance"), original);
        assertEq(vm.parseJsonUint(json, ".current_balance"), current);
        assertEq(vm.parseJsonString(json, ".name"), string.concat("HOLDINGS #", vm.toString(id)));
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "CASH");
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), "USD");
        assertEq(vm.parseJsonUint(json, ".attributes[2].value"), original);
        assertEq(vm.parseJsonUint(json, ".attributes[3].value"), current);
        assertEq(vm.parseJsonUint(json, ".attributes[4].value"), 1);

        string memory svg = _decodeImage(json);
        assertEq(svg, svgAfter, "image is the rendered SVG");
        assertTrue(_contains(svg, string.concat(">", holdings.displayText(id), "</text>")));
        if (original > 82_194_012) assertTrue(_contains(svg, ">$82,194,012</text>"));

        // A second outage changes it again.
        vm.prank(BOB);
        holdings.outage(id, 1000);
        assertEq(holdings.displayText(id), "$1,000");
        string memory json2 = _decodeJson(id);
        assertEq(vm.parseJsonUint(json2, ".current_balance"), 1000);
        assertEq(vm.parseJsonUint(json2, ".initial_balance"), original);
        assertTrue(_contains(_decodeImage(json2), ">$1,000</text>"));
    }

    function test_ethMetadata() public {
        uint256 id = _mintEthOfType(Holdings.HoldingType.ETH);
        (uint256 original,) = _balances(id);
        string memory json = _decodeJson(id);
        assertEq(vm.parseJsonString(json, ".holding_type"), "ETH");
        assertEq(vm.parseJsonString(json, ".currency"), "ETH");
        assertEq(vm.parseJsonUint(json, ".initial_balance"), original);
        assertEq(vm.parseJsonUint(json, ".current_balance"), original);
        string memory text = holdings.displayText(id);
        assertTrue(_contains(text, " ETH"));
        assertTrue(_contains(_decodeImage(json), string.concat(">", text, "</text>")));
        assertFalse(_contains(text, "$"));
    }

    function test_imdMetadata() public {
        uint256 id = _mintImd(ALICE);
        (uint256 original,) = _balances(id);
        string memory json = _decodeJson(id);
        assertEq(vm.parseJsonString(json, ".holding_type"), "IMD");
        assertEq(vm.parseJsonString(json, ".currency"), "IMD");
        assertEq(vm.parseJsonUint(json, ".initial_balance"), original);
        assertEq(vm.parseJsonUint(json, ".current_balance"), original);
        string memory text = holdings.displayText(id);
        assertTrue(_contains(text, " IMD"));
        assertTrue(_contains(_decodeImage(json), string.concat(">", text, "</text>")));
    }

    function test_svgIsPlainWhiteSquareWithBlackText() public {
        uint256 id = _mintImd(ALICE);
        string memory svg = holdings.tokenSVG(id);
        assertTrue(_contains(svg, 'viewBox="0 0 1000 1000"'));
        assertTrue(_contains(svg, '<rect width="1000" height="1000" fill="#ffffff"/>'));
        assertTrue(_contains(svg, 'fill="#000000"'));
        assertTrue(_contains(svg, 'text-anchor="middle"'));
        assertFalse(_contains(svg, "Gradient"));
        assertFalse(_contains(svg, "stroke"));
        assertFalse(_contains(svg, "http://") && !_contains(svg, "http://www.w3.org/2000/svg"));
        assertFalse(_contains(holdings.tokenURI(id), "ipfs"));
    }
}

contract HoldingsRenderingTest is Test {
    HoldingsHarness internal h;

    function setUp() public {
        h = new HoldingsHarness(address(0x0A11CE), address(0xDEAD0002));
    }

    function test_thousandsSeparators() public view {
        assertEq(h.withCommas(0), "0");
        assertEq(h.withCommas(1), "1");
        assertEq(h.withCommas(999), "999");
        assertEq(h.withCommas(1000), "1,000");
        assertEq(h.withCommas(12_345), "12,345");
        assertEq(h.withCommas(123_456), "123,456");
        assertEq(h.withCommas(1_234_567), "1,234,567");
        assertEq(h.withCommas(82_194_012), "82,194,012");
        assertEq(h.withCommas(1_000_000_000), "1,000,000,000");
    }

    function test_displayFormats() public view {
        assertEq(h.display(Holdings.HoldingType.ETH, 82_194_012), "82,194,012 ETH");
        assertEq(h.display(Holdings.HoldingType.IMD, 82_194_012), "82,194,012 IMD");
        assertEq(h.display(Holdings.HoldingType.CASH, 82_194_012), "$82,194,012");
        assertEq(h.display(Holdings.HoldingType.CASH, 0), "$0");
    }

    function _fontSize(string memory svg) internal pure returns (uint256) {
        uint256 start = vm.indexOf(svg, 'font-size="') + 11;
        bytes memory b = bytes(svg);
        uint256 v;
        for (uint256 i = start; b[i] != '"'; i++) {
            v = v * 10 + (uint8(b[i]) - 48);
        }
        return v;
    }

    function test_typographyScalesToFit() public view {
        uint256 big = _fontSize(h.svg("$0"));
        uint256 small = _fontSize(h.svg("1,000,000,000 ETH"));
        assertEq(big, 320);
        assertEq(small, 84);
        assertGt(big, small);
        // Every possible text (1..13 digits+commas, with suffix or "$") fits: 0.6em glyphs within 1000 units.
        uint256[6] memory samples = [uint256(0), 9, 999, 1_000, 82_194_012, 1_000_000_000];
        for (uint256 i; i < samples.length; i++) {
            for (uint256 t; t < 3; t++) {
                string memory text = h.display(Holdings.HoldingType(t), samples[i]);
                uint256 fs = _fontSize(h.svg(text));
                uint256 width = (fs * bytes(text).length * 6) / 10;
                assertLe(width, 900, "text wider than canvas minus margins");
                assertLe(fs, 320, "font taller than allowed");
            }
        }
    }

    function testFuzz_formattingRoundTrips(uint256 v) public view {
        v = bound(v, 0, 1_000_000_000);
        string memory s = h.withCommas(v);
        bytes memory b = bytes(s);
        uint256 parsed;
        uint256 digitsSinceComma;
        for (uint256 i; i < b.length; i++) {
            if (b[i] == ",") {
                assertEq(digitsSinceComma == 3 || (i > 0 && i <= 3), true);
                digitsSinceComma = 0;
            } else {
                parsed = parsed * 10 + (uint8(b[i]) - 48);
                digitsSinceComma++;
            }
        }
        assertEq(parsed, v);
        assertEq(b.length, bytes(vm.toString(v)).length + (bytes(vm.toString(v)).length - 1) / 3);
    }
}

contract HoldingsWithdrawTest is HoldingsTestBase {
    function test_ownerWithdrawsETH() public {
        _mintEth(ALICE);
        _mintEth(BOB);
        uint256 before = OWNER.balance;
        vm.prank(OWNER);
        holdings.withdrawETH();
        assertEq(OWNER.balance - before, 2 * ETH_PRICE);
        assertEq(address(holdings).balance, 0);
    }

    function test_ownerWithdrawsIMD() public {
        _mintImd(ALICE);
        _mintImd(BOB);
        vm.prank(OWNER);
        holdings.withdrawIMD();
        assertEq(imd.balanceOf(OWNER), 2 * IMD_PRICE);
        assertEq(imd.balanceOf(address(holdings)), 0);
    }

    function test_nonOwnerCannotWithdraw() public {
        _mintEth(ALICE);
        _mintImd(ALICE);
        address[3] memory callers = [ALICE, STRANGER, address(this)];
        for (uint256 i; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            holdings.withdrawETH();
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]));
            holdings.withdrawIMD();
        }
        assertEq(address(holdings).balance, ETH_PRICE);
        assertEq(imd.balanceOf(address(holdings)), IMD_PRICE);
    }

    function testFuzz_nonOwnerCannotWithdraw(address caller) public {
        vm.assume(caller != OWNER);
        _mintEth(ALICE);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        holdings.withdrawETH();
    }

    function test_withdrawNothingReverts() public {
        vm.startPrank(OWNER);
        vm.expectRevert(Holdings.NothingToWithdraw.selector);
        holdings.withdrawETH();
        vm.expectRevert(Holdings.NothingToWithdraw.selector);
        holdings.withdrawIMD();
        vm.stopPrank();
    }

    function test_pendingOwnerCannotWithdrawUntilAccepted() public {
        _mintEth(ALICE);
        vm.prank(OWNER);
        holdings.transferOwnership(BOB);
        assertEq(holdings.owner(), OWNER);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        holdings.withdrawETH();
        vm.prank(BOB);
        holdings.acceptOwnership();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        holdings.withdrawETH();
        vm.prank(BOB);
        holdings.withdrawETH();
        assertEq(BOB.balance, ETH_PRICE);
    }

    function test_renounceDisabled() public {
        vm.prank(OWNER);
        vm.expectRevert(Holdings.RenounceDisabled.selector);
        holdings.renounceOwnership();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        holdings.renounceOwnership();
        assertEq(holdings.owner(), OWNER);
    }

    function _contractOwner() internal returns (OwnerContract oc) {
        oc = new OwnerContract();
        oc.setHoldings(holdings);
        vm.prank(OWNER);
        holdings.transferOwnership(address(oc));
        oc.accept();
    }

    function test_withdrawToRejectingOwnerReverts() public {
        _mintEth(ALICE);
        OwnerContract oc = _contractOwner();
        oc.setMode(true, false);
        vm.expectRevert(Holdings.ETHTransferFailed.selector);
        oc.withdraw();
        assertEq(address(holdings).balance, ETH_PRICE);
    }

    function test_reentrantWithdrawBlocked() public {
        _mintEth(ALICE);
        _mintEth(BOB);
        OwnerContract oc = _contractOwner();
        oc.setMode(false, true);
        // The nested withdrawETH hits the reentrancy guard, so the ETH send fails and the whole call reverts.
        vm.expectRevert(Holdings.ETHTransferFailed.selector);
        oc.withdraw();
        assertEq(address(holdings).balance, 2 * ETH_PRICE);
        oc.setMode(false, false);
        oc.withdraw();
        assertEq(address(oc).balance, 2 * ETH_PRICE);
    }

    function test_fundsConservation() public {
        uint256 ethMints;
        uint256 imdMints;
        for (uint256 i; i < 30; i++) {
            if (i % 3 == 0) {
                _mintImd(address(uint160(0x70000 + i)));
                imdMints++;
            } else {
                _mintEth(address(uint160(0x70000 + i)));
                ethMints++;
            }
        }
        assertEq(address(holdings).balance, ethMints * ETH_PRICE);
        assertEq(imd.balanceOf(address(holdings)), imdMints * IMD_PRICE);
        assertEq(holdings.totalSupply(), ethMints + imdMints);
        vm.startPrank(OWNER);
        holdings.withdrawETH();
        holdings.withdrawIMD();
        vm.stopPrank();
        assertEq(OWNER.balance, ethMints * ETH_PRICE);
        assertEq(imd.balanceOf(OWNER), imdMints * IMD_PRICE);
    }
}
