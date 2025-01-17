// SPDX-License-Identifier: BSL 1.1 - Copyright 2024 MetaLayer Labs Ltd.
pragma solidity 0.8.15;
// @audit check - changes
import { AddressAliasHelper } from "src/vendor/AddressAliasHelper.sol";
import { Predeploys } from "src/libraries/Predeploys.sol";
import { CrossDomainMessenger } from "src/universal/CrossDomainMessenger.sol";
import { ISemver } from "src/universal/ISemver.sol";
import { L2ToL1MessagePasser } from "src/L2/L2ToL1MessagePasser.sol";
import { Constants } from "src/libraries/Constants.sol";
import { Blast, YieldMode, GasMode } from "src/L2/Blast.sol";

/// @custom:proxied
/// @custom:predeploy 0x4200000000000000000000000000000000000007
/// @title L2CrossDomainMessenger
/// @notice The L2CrossDomainMessenger is a high-level interface for message passing between L1 and
///         L2 on the L2 side. Users are generally encouraged to use this contract instead of lower
///         level message passing contracts.
contract L2CrossDomainMessenger is CrossDomainMessenger, ISemver {
    /// @custom:semver 1.7.0
    string public constant version = "1.7.0";

    /// @notice Constructs the L2CrossDomainMessenger contract.
    /// @param _l1CrossDomainMessenger Address of the L1CrossDomainMessenger contract.
    constructor(address _l1CrossDomainMessenger) CrossDomainMessenger(_l1CrossDomainMessenger) {
        _disableInitializers();
    }

    /// @notice Initializer.
    function initialize() public reinitializer(Constants.INITIALIZER) {
        __CrossDomainMessenger_init();
        Blast(Predeploys.BLAST).configureContract(
            address(this),
            YieldMode.VOID,
            GasMode.VOID,
            address(0xdead) /// don't set a governor
        );
    }

    /// @custom:legacy
    /// @notice Legacy getter for the remote messenger.
    ///         Use otherMessenger going forward.
    /// @return Address of the L1CrossDomainMessenger contract.
    function l1CrossDomainMessenger() public view returns (address) {
        return OTHER_MESSENGER;
    }

    /// @inheritdoc CrossDomainMessenger
    function _sendMessage(address _to, uint64 _gasLimit, uint256 _value, bytes memory _data) internal override {
        L2ToL1MessagePasser(payable(Predeploys.L2_TO_L1_MESSAGE_PASSER)).initiateWithdrawal{ value: _value }(
            _to, _gasLimit, _data
        );
    }

    /// @inheritdoc CrossDomainMessenger
    function _isOtherMessenger() internal view override returns (bool) {
        return AddressAliasHelper.undoL1ToL2Alias(msg.sender) == OTHER_MESSENGER;
    }

    /// @inheritdoc CrossDomainMessenger
    function _isUnsafeTarget(address _target) internal view override returns (bool) {
        return _target == address(this) || _target == address(Predeploys.L2_TO_L1_MESSAGE_PASSER) || _target == address(Predeploys.BLAST);
    }
}
