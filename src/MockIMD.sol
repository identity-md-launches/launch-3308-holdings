// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockIMD
/// @notice Worthless Sepolia stand-in for the IMD token (Ethereum mainnet 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7,
///         symbol IMD, 18 decimals). No official IMD token exists on Sepolia, so HOLDINGS' `mintWithIMD` is tested
///         against this one. Anyone can mint test tokens from the faucet; it has no owner and no admin.
/// @dev    Mirrors mainnet IMD's 18 decimals so HOLDINGS' price scaling is exercised the same way.
contract MockIMD is ERC20 {
    /// @notice Most a single `mint` call can create: 1,000 IMD.
    uint256 public constant MAX_MINT_PER_CALL = 1_000 ether;
    /// @notice What `faucet()` gives: 10 IMD, enough for 28 HOLDINGS mints.
    uint256 public constant FAUCET_AMOUNT = 10 ether;

    error MintTooLarge(uint256 requested, uint256 max);

    constructor() ERC20("Identity.md (Sepolia mock)", "IMD") {}

    /// @notice Mint `amount` test IMD to `to`. Open to anyone: this token is for testing only.
    function mint(address to, uint256 amount) external {
        if (amount > MAX_MINT_PER_CALL) revert MintTooLarge(amount, MAX_MINT_PER_CALL);
        _mint(to, amount);
    }

    /// @notice Mint `FAUCET_AMOUNT` test IMD to the caller.
    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
