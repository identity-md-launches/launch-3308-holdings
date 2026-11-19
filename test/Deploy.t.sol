// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Holdings} from "../src/Holdings.sol";
import {MockIMD} from "../src/MockIMD.sol";
import {DeployHoldings} from "../script/Deploy.s.sol";

contract DeployScriptTest is Test {
    address internal constant OWNER = 0xCcf0a1307E5e5Ad04E85d94d7f9D400390F0118a;
    DeployHoldings internal script;

    function setUp() public {
        script = new DeployHoldings();
    }

    function test_deployWithMockIMD() public {
        (Holdings holdings, address imd) =
            script.deploy(DeployHoldings.Config({owner: OWNER, deployMockIMD: true, imdToken: address(0)}));
        assertEq(holdings.owner(), OWNER);
        assertEq(address(holdings.IMD()), imd);
        assertEq(MockIMD(imd).symbol(), "IMD");
        assertEq(MockIMD(imd).decimals(), 18);
        assertEq(holdings.imdPrice(), 0.35 ether);
        assertEq(holdings.name(), "HOLDINGS");
        assertEq(holdings.symbol(), "HODL");
    }

    function test_deployWithExistingToken() public {
        MockIMD existing = new MockIMD();
        (Holdings holdings, address imd) =
            script.deploy(DeployHoldings.Config({owner: OWNER, deployMockIMD: false, imdToken: address(existing)}));
        assertEq(imd, address(existing));
        assertEq(address(holdings.IMD()), address(existing));
    }

    function test_deployWithoutTokenReverts() public {
        vm.expectRevert(DeployHoldings.MissingIMDToken.selector);
        script.deploy(DeployHoldings.Config({owner: OWNER, deployMockIMD: false, imdToken: address(0)}));
    }

    function test_deployRejectsZeroOwner() public {
        vm.expectRevert();
        script.deploy(DeployHoldings.Config({owner: address(0), deployMockIMD: true, imdToken: address(0)}));
    }
}

/// @notice The Sepolia demonstration, rehearsed: ETH mint, IMD mint, and an outage that changes a CASH SVG.
contract DemoScenarioTest is Test {
    address internal constant OWNER = 0xCcf0a1307E5e5Ad04E85d94d7f9D400390F0118a;
    address internal constant MINTER = address(0xD3E0);

    function test_demoScenario() public {
        MockIMD imd = new MockIMD();
        Holdings holdings = new Holdings(OWNER, address(imd));
        vm.deal(MINTER, 1 ether);

        vm.startPrank(MINTER);
        // ETH mints until one yields CASH (each has a 50% chance).
        uint256 cashId;
        for (uint256 i; i < 32 && cashId == 0; i++) {
            vm.prevrandao(bytes32(i + 1));
            uint256 id = holdings.mint{value: holdings.ETH_PRICE()}();
            (Holdings.HoldingType t,,,) = holdings.getHolding(id);
            if (t == Holdings.HoldingType.CASH) cashId = id;
        }
        assertGt(cashId, 0);

        imd.faucet();
        imd.approve(address(holdings), holdings.imdPrice());
        uint256 imdId = holdings.mintWithIMD();
        (Holdings.HoldingType it,,,) = holdings.getHolding(imdId);
        assertTrue(it == Holdings.HoldingType.IMD);
        vm.stopPrank();

        string memory before = holdings.tokenSVG(cashId);
        vm.prank(address(0xBEEF));
        holdings.outage(cashId, 1_234);
        string memory afterSvg = holdings.tokenSVG(cashId);
        assertTrue(keccak256(bytes(before)) != keccak256(bytes(afterSvg)));
        assertTrue(vm.indexOf(afterSvg, ">$1,234</text>") != type(uint256).max);
    }
}

contract MockIMDTest is Test {
    MockIMD internal imd;

    function setUp() public {
        imd = new MockIMD();
    }

    function test_metadata() public view {
        assertEq(imd.symbol(), "IMD");
        assertEq(imd.decimals(), 18);
        assertEq(imd.totalSupply(), 0);
    }

    function test_faucet() public {
        vm.prank(address(0xA1));
        imd.faucet();
        assertEq(imd.balanceOf(address(0xA1)), 10 ether);
    }

    function test_mintCapped() public {
        imd.mint(address(0xA1), 1_000 ether);
        assertEq(imd.balanceOf(address(0xA1)), 1_000 ether);
        vm.expectRevert(abi.encodeWithSelector(MockIMD.MintTooLarge.selector, 1_000 ether + 1, 1_000 ether));
        imd.mint(address(0xA1), 1_000 ether + 1);
    }
}
