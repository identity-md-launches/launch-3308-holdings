// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Holdings} from "../src/Holdings.sol";
import {MockIMD} from "../src/MockIMD.sol";

/// @dev Drives Holdings with bounded random calls from several actors. Every call goes through try/catch and is
///      classified: a call that should have succeeded but reverted, or should have reverted but succeeded, is counted
///      in `unexpected`, which the invariants require to stay zero.
contract HoldingsHandler is Test {
    uint256 internal constant ETH_PRICE = 0.00056 ether;
    uint256 internal constant IMD_PRICE = 0.35 ether;
    uint256 internal constant MAX_SUPPLY = 1_000;

    Holdings public immutable holdings;
    MockIMD public immutable imd;
    address public immutable owner;
    address[] public actors;

    // Ghost accounting
    uint256 public ethMints;
    uint256 public imdMints;
    uint256 public ethPaidIn;
    uint256 public imdPaidIn;
    uint256 public ethForced;
    uint256 public imdDonated;
    uint256 public ethWithdrawn;
    uint256 public imdWithdrawn;
    uint256 public outages;
    uint256 public soldOutReverts;
    uint256 public unexpected;
    string public lastUnexpected;

    mapping(uint256 => Holdings.HoldingType) public ghostType;
    mapping(uint256 => uint256) public ghostOriginal;
    mapping(uint256 => uint256) public ghostCurrent;
    mapping(uint256 => uint256) public ghostOutages;
    mapping(uint256 => bool) public ghostPaidWithIMD;

    constructor(Holdings h, MockIMD t, address owner_) {
        holdings = h;
        imd = t;
        owner = owner_;
        actors.push(address(0xA1));
        actors.push(address(0xA2));
        actors.push(address(0xA3));
        actors.push(address(0xA4));
        actors.push(owner_); // the owner mints and causes outages like anyone else
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _flag(string memory why) internal {
        unexpected += 1;
        lastUnexpected = why;
    }

    function _recordMint(uint256 id, bool paidWithIMD) internal {
        (Holdings.HoldingType t, uint256 original, uint256 current,) = holdings.getHolding(id);
        if (id != ethMints + imdMints) _flag("token id not sequential");
        if (original < 1 || original > 1_000_000_000) _flag("balance out of range");
        if (current != original) _flag("fresh token current != original");
        if (paidWithIMD && t != Holdings.HoldingType.IMD) _flag("IMD mint did not give IMD");
        if (!paidWithIMD && t == Holdings.HoldingType.IMD) _flag("ETH mint gave IMD");
        ghostType[id] = t;
        ghostOriginal[id] = original;
        ghostCurrent[id] = current;
        ghostPaidWithIMD[id] = paidWithIMD;
    }

    function _advance(bytes32 randao) internal {
        vm.prevrandao(randao);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    /// @dev ETH mint with the exact price most of the time, a wrong amount otherwise.
    function mintEth(uint256 actorSeed, uint256 valueSeed, bytes32 randao) external {
        _advance(randao);
        address a = _actor(actorSeed);
        uint256 value = valueSeed % 3 == 0 ? bound(valueSeed, 0, 2 * ETH_PRICE) : ETH_PRICE;
        bool full = holdings.totalSupply() >= MAX_SUPPLY;
        vm.deal(a, value);
        vm.prank(a);
        try holdings.mint{value: value}() returns (uint256 id) {
            if (value != ETH_PRICE) _flag("mint accepted wrong ETH");
            if (full) _flag("mint past cap");
            ethMints += 1;
            ethPaidIn += value;
            _recordMint(id, false);
        } catch (bytes memory err) {
            if (value == ETH_PRICE && !full) _flag("valid ETH mint reverted");
            if (full && value == ETH_PRICE) {
                if (bytes4(err) != Holdings.SoldOut.selector) _flag("wrong error at cap");
                soldOutReverts += 1;
            }
        }
    }

    /// @dev Mints up to 40 tokens at the exact price, to reach the supply cap within a run.
    function mintEthBatch(uint256 actorSeed, uint256 n, bytes32 randao) external {
        n = bound(n, 1, 40);
        for (uint256 i; i < n; i++) {
            this.mintEth((actorSeed % 1_000) + i, 1, keccak256(abi.encode(randao, i)));
        }
    }

    /// @dev IMD mint where the minter's approval or balance is sometimes short of the price.
    function mintImd(uint256 actorSeed, uint256 mode, uint256 shortBy, bytes32 randao) external {
        _advance(randao);
        address a = _actor(actorSeed);
        shortBy = bound(shortBy, 1, IMD_PRICE);
        mode = mode % 4;
        uint256 approveAmt = mode == 1 ? IMD_PRICE - shortBy : IMD_PRICE + (mode == 3 ? shortBy : 0);
        uint256 have = imd.balanceOf(a);
        uint256 want = mode == 2 ? IMD_PRICE - shortBy : IMD_PRICE;
        if (have < want) {
            imd.mint(a, want - have);
        } else if (have > want) {
            vm.prank(a);
            imd.transfer(address(0xdead), have - want);
        }
        vm.prank(a);
        imd.approve(address(holdings), approveAmt);
        bool ok = mode != 1 && mode != 2;
        bool full = holdings.totalSupply() >= MAX_SUPPLY;
        uint256 beforeBal = imd.balanceOf(address(holdings));
        vm.prank(a);
        try holdings.mintWithIMD() returns (uint256 id) {
            if (!ok) _flag("mintWithIMD accepted short payment");
            if (full) _flag("IMD mint past cap");
            if (imd.balanceOf(address(holdings)) - beforeBal != IMD_PRICE) _flag("IMD received != price");
            if (imd.allowance(a, address(holdings)) != approveAmt - IMD_PRICE) _flag("allowance not spent exactly");
            imdMints += 1;
            imdPaidIn += IMD_PRICE;
            _recordMint(id, true);
        } catch {
            if (ok && !full) _flag("valid IMD mint reverted");
            if (ok && full) soldOutReverts += 1;
        }
    }

    /// @dev Anyone lowers (or tries to raise / keep) any token's balance.
    function outage(uint256 actorSeed, uint256 tokenSeed, uint256 newSeed, bool lower) external {
        uint256 supply = holdings.totalSupply();
        uint256 id = supply == 0 ? 1 : bound(tokenSeed, 1, supply + 1); // supply+1 does not exist
        address a = _actor(actorSeed);
        bool exists = id <= supply;
        uint256 cur = ghostCurrent[id];
        uint256 nb;
        if (lower && cur > 0) nb = bound(newSeed, 0, cur - 1);
        else nb = bound(newSeed, cur, type(uint256).max);
        bool ok = exists && ghostType[id] == Holdings.HoldingType.CASH && nb < cur;
        vm.prank(a);
        try holdings.outage(id, nb) {
            if (!ok) _flag("outage accepted invalid call");
            ghostCurrent[id] = nb;
            ghostOutages[id] += 1;
            outages += 1;
            (,, uint256 current,) = holdings.getHolding(id);
            if (current != nb) _flag("outage did not set balance");
        } catch {
            if (ok) _flag("valid outage reverted");
        }
    }

    function transfer(uint256 fromSeed, uint256 tokenSeed, uint256 toSeed) external {
        uint256 supply = holdings.totalSupply();
        if (supply == 0) return;
        uint256 id = bound(tokenSeed, 1, supply);
        address from = holdings.ownerOf(id);
        address to = _actor(toSeed);
        address caller = _actor(fromSeed);
        bool ok = caller == from;
        vm.prank(caller);
        try holdings.transferFrom(from, to, id) {
            if (!ok) _flag("transfer by non-holder");
        } catch {
            if (ok) _flag("holder transfer reverted");
        }
    }

    function withdrawETH(uint256 callerSeed) external {
        address c = callerSeed % 2 == 0 ? owner : _actor(callerSeed);
        uint256 bal = address(holdings).balance;
        bool ok = c == owner && bal > 0;
        uint256 before = owner.balance;
        vm.prank(c);
        try holdings.withdrawETH() {
            if (!ok) _flag("withdrawETH by non-owner or empty");
            if (owner.balance - before != bal) _flag("withdrawETH paid wrong amount");
            ethWithdrawn += bal;
        } catch {
            if (ok) _flag("owner withdrawETH reverted");
        }
    }

    function withdrawIMD(uint256 callerSeed) external {
        address c = callerSeed % 2 == 0 ? owner : _actor(callerSeed);
        uint256 bal = imd.balanceOf(address(holdings));
        bool ok = c == owner && bal > 0;
        uint256 before = imd.balanceOf(owner);
        vm.prank(c);
        try holdings.withdrawIMD() {
            if (!ok) _flag("withdrawIMD by non-owner or empty");
            if (imd.balanceOf(owner) - before != bal) _flag("withdrawIMD paid wrong amount");
            imdWithdrawn += bal;
        } catch {
            if (ok) _flag("owner withdrawIMD reverted");
        }
    }

    /// @dev ETH forced in without a mint (selfdestruct / coinbase), and IMD sent by plain transfer.
    function donate(uint256 ethAmt, uint256 imdAmt) external {
        ethAmt = bound(ethAmt, 0, 1 ether);
        imdAmt = bound(imdAmt, 0, 10 ether);
        vm.deal(address(holdings), address(holdings).balance + ethAmt);
        ethForced += ethAmt;
        imd.mint(address(holdings), imdAmt);
        imdDonated += imdAmt;
    }

    /// @dev Non-owners try owner-only and ownership calls.
    function hijack(uint256 actorSeed, address to) external {
        address a = _actor(actorSeed);
        if (a == owner) return;
        vm.prank(a);
        try holdings.transferOwnership(to) {
            _flag("non-owner transferred ownership");
        } catch {}
        vm.prank(a);
        try holdings.renounceOwnership() {
            _flag("renounce succeeded");
        } catch {}
    }
}

/// forge-config: default.invariant.runs = 16
contract HoldingsInvariantTest is Test {
    address internal constant OWNER = address(0x0A11CE);
    uint256 internal constant ETH_PRICE = 0.00056 ether;

    Holdings internal holdings;
    MockIMD internal imd;
    HoldingsHandler internal handler;

    function setUp() public {
        imd = new MockIMD();
        holdings = new Holdings(OWNER, address(imd));
        handler = new HoldingsHandler(holdings, imd, OWNER);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = HoldingsHandler.mintEth.selector;
        sel[1] = HoldingsHandler.mintEthBatch.selector;
        sel[2] = HoldingsHandler.mintImd.selector;
        sel[3] = HoldingsHandler.outage.selector;
        sel[4] = HoldingsHandler.transfer.selector;
        sel[5] = HoldingsHandler.withdrawETH.selector;
        sel[6] = HoldingsHandler.withdrawIMD.selector;
        sel[7] = HoldingsHandler.donate.selector;
        sel[8] = HoldingsHandler.hijack.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    function invariant_noUnexpectedOutcome() public view {
        assertEq(handler.unexpected(), 0, handler.lastUnexpected());
    }

    function invariant_supplyCappedAndCounted() public view {
        uint256 supply = holdings.totalSupply();
        assertLe(supply, 1_000);
        assertEq(supply, handler.ethMints() + handler.imdMints());
        uint256 held;
        for (uint256 i; i < handler.actorCount(); i++) {
            held += holdings.balanceOf(handler.actors(i));
        }
        assertEq(held, supply, "every token is held by an actor");
    }

    function invariant_ethConserved() public view {
        assertEq(handler.ethPaidIn(), handler.ethMints() * ETH_PRICE, "only the exact price was ever accepted");
        assertEq(
            address(holdings).balance + handler.ethWithdrawn(),
            handler.ethPaidIn() + handler.ethForced(),
            "ETH held + withdrawn == paid in"
        );
    }

    function invariant_imdConserved() public view {
        assertEq(
            imd.balanceOf(address(holdings)) + handler.imdWithdrawn(),
            handler.imdPaidIn() + handler.imdDonated(),
            "IMD held + withdrawn == paid in"
        );
    }

    function invariant_ownerUnchanged() public view {
        assertEq(holdings.owner(), OWNER);
        assertEq(holdings.pendingOwner(), address(0));
    }

    /// @dev Per token: type and original fixed forever; ETH/IMD current == original; CASH current only ever equals
    ///      the last accepted outage and never exceeds the original.
    function _checkToken(uint256 id) internal view returns (bool isImd) {
        (Holdings.HoldingType t, uint256 original, uint256 current,) = holdings.getHolding(id);
        assertEq(uint8(t), uint8(handler.ghostType(id)), "holding type changed");
        assertEq(original, handler.ghostOriginal(id), "original changed");
        assertGe(original, 1);
        assertLe(original, 1_000_000_000);
        assertEq(current, handler.ghostCurrent(id), "current differs from last outage");
        assertLe(current, original);
        assertEq(holdings.outageCount(id), handler.ghostOutages(id));
        if (t != Holdings.HoldingType.CASH) {
            assertEq(current, original, "ETH/IMD balance changed");
            assertEq(handler.ghostOutages(id), 0);
        }
        if (t == Holdings.HoldingType.IMD) {
            assertTrue(handler.ghostPaidWithIMD(id));
            isImd = true;
        }
    }

    /// @dev After every call: a sample of 12 tokens that moves with the block number (the handler rolls it).
    function invariant_holdingsPermanentSample() public view {
        uint256 supply = holdings.totalSupply();
        if (supply == 0) return;
        for (uint256 k; k < 12; k++) {
            _checkToken(((block.number * 7919 + k * 613) % supply) + 1);
        }
        _checkToken(supply); // the newest token
    }

    /// @dev At the end of every run: every token, and IMD holdings exist only from IMD payments.
    function afterInvariant() public view {
        uint256 supply = holdings.totalSupply();
        uint256 imdTyped;
        for (uint256 id = 1; id <= supply; id++) {
            if (_checkToken(id)) imdTyped++;
        }
        assertEq(imdTyped, handler.imdMints(), "IMD holdings == IMD mints");
        assertEq(handler.unexpected(), 0, handler.lastUnexpected());
    }
}

/// @dev The handler is not vacuous: driven directly it reaches the cap, sees SoldOut on both payment paths, and
///      classifies every outcome as expected.
contract HoldingsHandlerSanityTest is Test {
    function test_handlerReachesCapAndStaysClean() public {
        MockIMD imd = new MockIMD();
        Holdings holdings = new Holdings(address(0x0A11CE), address(imd));
        HoldingsHandler handler = new HoldingsHandler(holdings, imd, address(0x0A11CE));
        for (uint256 i; i < 26; i++) {
            handler.mintEthBatch(i, 40, keccak256(abi.encode(i)));
            handler.mintImd(i, 0, 1, keccak256(abi.encode("imd", i)));
            handler.outage(i, i * 31, i * 7, true);
        }
        assertEq(holdings.totalSupply(), 1_000);
        handler.mintEth(1, 1, bytes32(uint256(1)));
        handler.mintImd(2, 0, 1, bytes32(uint256(2)));
        assertGt(handler.soldOutReverts(), 1);
        assertGt(handler.imdMints(), 0);
        assertGt(handler.outages(), 0);
        handler.withdrawETH(0);
        handler.withdrawIMD(0);
        assertEq(address(holdings).balance, 0);
        assertEq(handler.unexpected(), 0, handler.lastUnexpected());
    }
}
