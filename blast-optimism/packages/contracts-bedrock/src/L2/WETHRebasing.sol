// SPDX-License-Identifier: BSL 1.1 - Copyright 2024 MetaLayer Labs Ltd.
pragma solidity 0.8.15;
// @audit check - changes
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";

import { Blast, YieldMode } from "src/L2/Blast.sol";
import { GasMode } from "src/L2/Gas.sol";
import { ERC20Rebasing } from "src/L2/ERC20Rebasing.sol";
import { SharesBase } from "src/L2/Shares.sol";
import { Predeploys } from "src/libraries/Predeploys.sol";
import { Semver } from "src/universal/Semver.sol";

/// @custom:proxied
/// @custom:predeploy 0x4300000000000000000000000000000000000004
/// @title WETHRebasing
/// @notice Rebasing ERC20 token that serves as WETH on Blast L2.
/// Although the WETH token builds on top of the already rebasing native ether,
/// it has its own configuration and shares accounting. However, it’s the only token
/// that does not receive a yield report.
///
/// An additional complexity with WETH is that since it holds native ether,
/// its own balance is rebasing. Therefore, we could just base the WETH share price on the ether price,
/// however, users and contracts are able to opt-out of receiving yield, while their funds are still
/// gaining yield for the WETH contract. Using the native ether share price would leave yields
/// in the WETH contract that are unallocated due to the VOID balances. To resolve this, WETH has
/// its own share price that’s computed based on its current balance and removing void funds
/// so the yields are only divided amongst the active funds.
contract WETHRebasing is ERC20Rebasing, Semver {
    /// @notice Emitted whenever tokens are deposited to an account.
    /// @param account Address of the account tokens are being deposited to.
    /// @param amount  Amount of tokens deposited.
    event Deposit(address indexed account, uint amount);

    /// @notice Emitted whenever tokens are withdrawn from an account.
    /// @param account Address of the account tokens are being withdrawn from.
    /// @param amount  Amount of tokens withdrawn.
    event Withdrawal(address indexed account, uint amount);

    error ETHTransferFailed();

    /// @custom:semver 1.0.0
    constructor()
        ERC20Rebasing(Predeploys.SHARES, 18)
        Semver(1, 0, 0)
    {
        _disableInitializers();
    }

    /// @notice Initializer.
    function initialize() external initializer {
        __ERC20Rebasing_init(
            "Wrapped Ether",
            "WETH",
            SharesBase(Predeploys.SHARES).price()
        );
        Blast(Predeploys.BLAST).configureContract(
            address(this),
            YieldMode.AUTOMATIC,
            GasMode.VOID,
            address(0xdead) /// don't set a governor
        );
    }

    /// @notice Allows a user to send ETH directly and have
    ///         their balance updated.
    receive() external payable {
        deposit();
    }

    /// @notice Deposit ETH and increase the wrapped balance.
    function deposit() public payable {
        address account = msg.sender;
        _deposit(account, msg.value);

        emit Deposit(account, msg.value);
    }

    /// @notice Withdraw ETH and decrease the wrapped balance.
    /// @param wad Amount to withdraw.
    function withdraw(uint256 wad) public {
        address account = msg.sender;
        _withdraw(account, wad);

        (bool success,) = account.call{value: wad}("");
        if (!success) revert ETHTransferFailed();

        emit Withdrawal(account, wad);
    }

    /// @notice Update the share price based on the rebased contract balance.
    function _addValue(uint256) internal override {
        if (msg.sender != REPORTER) {
            revert InvalidReporter();
        }

        uint256 yieldBearingEth = price * _totalShares;
        uint256 pending = address(this).balance - yieldBearingEth - _totalVoidAndRemainders;
        if (pending < _totalShares || _totalShares == 0) {
            return;
        }

        price += (pending / _totalShares);
    }
}
