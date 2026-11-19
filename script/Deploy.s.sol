// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Holdings} from "../src/Holdings.sol";
import {MockIMD} from "../src/MockIMD.sol";

/// @notice Deploys HOLDINGS on Sepolia, with a MockIMD unless an existing IMD token address is given.
/// @dev `run()` only reads the environment and broadcasts; `deploy(Config)` holds the logic and is tested directly.
///      Environment for `run()`:
///        HOLDINGS_OWNER   owner of HOLDINGS (receives withdrawals) - required
///        IMD_TOKEN        an existing IMD ERC-20 to accept - optional; when unset a MockIMD is deployed
///      Example:
///        forge script script/Deploy.s.sol:DeployHoldings --rpc-url sepolia --account <keystore> --broadcast --verify
contract DeployHoldings is Script {
    struct Config {
        address owner;
        bool deployMockIMD;
        address imdToken; // used only when deployMockIMD is false
    }

    error MissingIMDToken();

    function run() external returns (Holdings holdings, address imd) {
        Config memory cfg;
        cfg.owner = vm.envAddress("HOLDINGS_OWNER");
        cfg.imdToken = vm.envOr("IMD_TOKEN", address(0));
        cfg.deployMockIMD = cfg.imdToken == address(0);
        vm.startBroadcast();
        (holdings, imd) = deploy(cfg);
        vm.stopBroadcast();
        console2.log("IMD token:", imd);
        console2.log("HOLDINGS:", address(holdings));
    }

    function deploy(Config memory cfg) public returns (Holdings holdings, address imd) {
        if (cfg.deployMockIMD) {
            imd = address(new MockIMD());
        } else {
            if (cfg.imdToken == address(0)) revert MissingIMDToken();
            imd = cfg.imdToken;
        }
        holdings = new Holdings(cfg.owner, imd);
    }
}
