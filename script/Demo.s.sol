// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Holdings} from "../src/Holdings.sol";
import {MockIMD} from "../src/MockIMD.sol";

/// @notice Step 1 of the Sepolia demonstration: one ETH mint and one IMD mint from the broadcasting wallet.
/// @dev Environment: HOLDINGS (address of the deployed collection). The IMD side takes test IMD from the MockIMD
///      faucet, approves exactly 0.35 IMD and mints.
///        forge script script/Demo.s.sol:DemoMint --rpc-url sepolia --account <keystore> --broadcast
///      The holding type and balance are drawn on chain when the transaction is mined, so read the result from
///      `getHolding` / the HoldingMinted event afterwards, not from the simulation. Repeat until an ETH mint gives a
///      CASH holding (50% each time).
contract DemoMint is Script {
    function run() external {
        Holdings holdings = Holdings(vm.envAddress("HOLDINGS"));
        MockIMD imd = MockIMD(address(holdings.IMD()));
        uint256 price = holdings.imdPrice();
        vm.startBroadcast();
        uint256 ethToken = holdings.mint{value: holdings.ETH_PRICE()}();
        imd.faucet();
        imd.approve(address(holdings), price);
        uint256 imdToken = holdings.mintWithIMD();
        vm.stopBroadcast();
        console2.log("ETH-paid token id:", ethToken);
        console2.log("IMD-paid token id:", imdToken);
    }
}

/// @notice Step 2 of the demonstration: an outage on a CASH token, showing the SVG before and after.
/// @dev Environment: HOLDINGS, TOKEN_ID (a CASH token), NEW_BALANCE (strictly below its current balance).
///        forge script script/Demo.s.sol:DemoOutage --rpc-url sepolia --account <keystore> --broadcast
contract DemoOutage is Script {
    function run() external {
        Holdings holdings = Holdings(vm.envAddress("HOLDINGS"));
        uint256 tokenId = vm.envUint("TOKEN_ID");
        uint256 newBalance = vm.envUint("NEW_BALANCE");
        console2.log("SVG before:", holdings.tokenSVG(tokenId));
        vm.startBroadcast();
        holdings.outage(tokenId, newBalance);
        vm.stopBroadcast();
        console2.log("SVG after:", holdings.tokenSVG(tokenId));
    }
}
