pragma solidity 0.8.15;
// @audit check - changes

import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

enum GasMode {
    VOID,
    CLAIMABLE
}

interface IGas {
    function readGasParams(address contractAddress) external view returns (uint256, uint256, uint256, GasMode);
    function setGasMode(address contractAddress, GasMode mode) external;
    function claimGasAtMinClaimRate(address contractAddress, address recipient, uint256 minClaimRateBips) external returns (uint256);
    function claimAll(address contractAddress, address recipient) external returns (uint256);
    function claimMax(address contractAddress, address recipient) external returns (uint256);
    function claim(address contractAddress, address recipient, uint256 gasToClaim, uint256 gasSecondsToConsume) external returns (uint256);
}

contract Gas is IGas {
    address public immutable admin;

    // Blast.sol --> controls all dAPP accesses to Gas.sol
    address public immutable blastConfigurationContract;

    // BaseFeeVault.sol -> fees from gas claims directed here
    address public immutable blastFeeVault;

    // zero claim rate in bps -> percent of gas user is able to claim
    // without consuming any gas seconds
    uint256 public zeroClaimRate; // bps

    // base claim rate in bps -> percent of gas user is able to claim
    // by consuming base gas seconds
    uint256 public baseGasSeconds;
    uint256 public baseClaimRate; // bps

    // ceil claim rate in bps -> percent of gas user is able to claim
    // by consuming ceil gas seconds or more
    uint256 public ceilGasSeconds;
    uint256 public ceilClaimRate; // bps

    /**
     * @notice Constructs the blast gas contract.
     * @param _admin The address of the admin.
     * @param _blastConfigurationContract The address of the Blast configuration contract.
     * @param _blastFeeVault The address of the Blast fee vault.
     * @param _zeroClaimRate The zero claim rate.
     * @param _baseGasSeconds The base gas seconds.
     * @param _baseClaimRate The base claim rate.
     * @param _ceilGasSeconds The ceiling gas seconds.
     * @param _ceilClaimRate The ceiling claim rate.
     */
    constructor(
        address _admin,
        address _blastConfigurationContract,
        address _blastFeeVault,
        uint256 _zeroClaimRate,
        uint256 _baseGasSeconds,
        uint256 _baseClaimRate,
        uint256 _ceilGasSeconds,
        uint256 _ceilClaimRate
    ) {
        require(_zeroClaimRate < _baseClaimRate, "zero claim rate must be < base claim rate");
        require(_baseClaimRate < _ceilClaimRate, "base claim rate must be < ceil claim rate");
        require(_baseGasSeconds < _ceilGasSeconds, "base gas seconds must be < ceil gas seconds");
        require(_baseGasSeconds > 0, "base gas seconds must be > 0");
        require(_ceilClaimRate <= 10000, "ceil claim rate must be less than or equal to 10_000 bips");
        // admin vars
        admin =  _admin;
        blastConfigurationContract = _blastConfigurationContract;
        blastFeeVault = _blastFeeVault;
        zeroClaimRate = _zeroClaimRate;
        baseGasSeconds = _baseGasSeconds;
        baseClaimRate = _baseClaimRate;
        ceilGasSeconds = _ceilGasSeconds;
        ceilClaimRate = _ceilClaimRate;
    }

    /**
     * @notice Allows only the admin to call a function
     */
    modifier onlyAdmin() {
        require(msg.sender == admin, "Caller is not the admin");
        _;
    }
    /**
     * @notice Allows only the Blast Configuration Contract to call a function
     */
    modifier onlyBlastConfigurationContract() {
        require(msg.sender == blastConfigurationContract, "Caller must be blast configuration contract");
        _;
    }

    /**
     * @notice Allows the admin to update the parameters
     * @param _zeroClaimRate The new zero claim rate
     * @param _baseGasSeconds The new base gas seconds
     * @param _baseClaimRate The new base claim rate
     * @param _ceilGasSeconds The new ceiling gas seconds
     * @param _ceilClaimRate The new ceiling claim rate
     */
    function updateAdminParameters(
        uint256 _zeroClaimRate,
        uint256 _baseGasSeconds,
        uint256 _baseClaimRate,
        uint256 _ceilGasSeconds,
        uint256 _ceilClaimRate
    ) external onlyAdmin {
        require(_zeroClaimRate < _baseClaimRate, "zero claim rate must be < base claim rate");
        require(_baseClaimRate < _ceilClaimRate, "base claim rate must be < ceil claim rate");
        require(_baseGasSeconds < _ceilGasSeconds, "base gas seconds must be < ceil gas seconds");
        require(_baseGasSeconds > 0, "base gas seconds must be > 0");
        require(_ceilClaimRate <= 10000, "ceil claim rate must be less than or equal to 10_000 bips");

        zeroClaimRate = _zeroClaimRate;
        baseGasSeconds = _baseGasSeconds;
        baseClaimRate = _baseClaimRate;
        ceilGasSeconds = _ceilGasSeconds;
        ceilClaimRate = _ceilClaimRate;
    }

    /**
     * @notice Allows the admin to claim the gas of any address
     * @param contractAddress The address of the contract
     * @return The amount of ether balance claimed
     */
    function adminClaimGas(address contractAddress) external onlyAdmin returns (uint256) {
        (, uint256 etherBalance,,) = readGasParams(contractAddress);
        _updateGasParams(contractAddress, 0, 0, GasMode.VOID);
        SafeTransferLib.safeTransferETH(blastFeeVault, etherBalance);
        return etherBalance;
    }
    /**
     * @notice Allows an authorized user to set the gas mode for a contract via the BlastConfigurationContract
     * @param contractAddress The address of the contract
     * @param mode The new gas mode for the contract
     */
    function setGasMode(address contractAddress, GasMode mode) external onlyBlastConfigurationContract {
        // retrieve gas params
        (uint256 etherSeconds, uint256 etherBalance,,) = readGasParams(contractAddress);
        _updateGasParams(contractAddress, etherSeconds, etherBalance, mode);
    }

    /**
     * @notice Allows a user to claim gas at a minimum claim rate
     * @param contractAddress The address of the contract
     * @param recipientOfGas The address of the recipient of the gas
     * @param minClaimRateBips The minimum claim rate in basis points
     * @return The amount of gas claimed
     */
    function claimGasAtMinClaimRate(address contractAddress, address recipientOfGas, uint256 minClaimRateBips) public returns (uint256) {
        require(minClaimRateBips <= ceilClaimRate, "desired claim rate exceeds maximum");

        (uint256 etherSeconds, uint256 etherBalance,,) = readGasParams(contractAddress);
        if (minClaimRateBips <= zeroClaimRate) {
            return claimAll(contractAddress, recipientOfGas);
        }

        // set minClaimRate to baseClaimRate in this case
        if (minClaimRateBips < baseClaimRate) {
            minClaimRateBips = baseClaimRate;
        }

        uint256 bipsDiff = minClaimRateBips - baseClaimRate;
        uint256 secondsDiff = ceilGasSeconds - baseGasSeconds;
        uint256 rateDiff = ceilClaimRate - baseClaimRate;
        uint256 minSecondsStaked = baseGasSeconds + Math.ceilDiv(bipsDiff * secondsDiff, rateDiff);
        uint256 maxEtherClaimable = etherSeconds / minSecondsStaked;
        if (maxEtherClaimable > etherBalance)  {
            maxEtherClaimable = etherBalance;
        }
        uint256 secondsToConsume = maxEtherClaimable * minSecondsStaked;
        return claim(contractAddress, recipientOfGas, maxEtherClaimable, secondsToConsume);
    }

    /**
     * @notice Allows a contract to claim all gas
     * @param contractAddress The address of the contract
     * @param recipientOfGas The address of the recipient of the gas
     * @return The amount of gas claimed
     */
    function claimAll(address contractAddress, address recipientOfGas) public returns (uint256) {
        (uint256 etherSeconds, uint256 etherBalance,,) = readGasParams(contractAddress);
        return claim(contractAddress, recipientOfGas, etherBalance, etherSeconds);
    }

    /**
     * @notice Allows a contract to claim all gas at the highest possible claim rate
     * @param contractAddress The address of the contract
     * @param recipientOfGas The address of the recipient of the gas
     * @return The amount of gas claimed
     */
    function claimMax(address contractAddress, address recipientOfGas) public returns (uint256) {
        return claimGasAtMinClaimRate(contractAddress, recipientOfGas, ceilClaimRate);
    }
    /**
     * @notice Allows a contract to claim a specified amount of gas, at a claim rate set by the number of gas seconds
     * @param contractAddress The address of the contract
     * @param recipientOfGas The address of the recipient of the gas
     * @param gasToClaim The amount of gas to claim
     * @param gasSecondsToConsume The amount of gas seconds to consume
     * @return The amount of gas claimed (gasToClaim - penalty)
     */

    function claim(address contractAddress, address recipientOfGas, uint256 gasToClaim, uint256 gasSecondsToConsume) public onlyBlastConfigurationContract() returns (uint256)  {
        // retrieve gas params
        (uint256 etherSeconds, uint256 etherBalance,, GasMode mode) = readGasParams(contractAddress);

        // check validity requirements
        require(gasToClaim > 0, "must withdraw non-zero amount");
        require(gasToClaim <= etherBalance, "too much to withdraw");
        require(gasSecondsToConsume <= etherSeconds, "not enough gas seconds");

        // get claim rate
        (uint256 claimRate, uint256 gasSecondsToConsumeNormalized) = getClaimRateBps(gasSecondsToConsume, gasToClaim);

        // calculate tax
        uint256 userEther = gasToClaim * claimRate / 10_000;
        uint256 penalty = gasToClaim - userEther;

        _updateGasParams(contractAddress, etherSeconds - gasSecondsToConsumeNormalized, etherBalance - gasToClaim, mode);

        SafeTransferLib.safeTransferETH(recipientOfGas, userEther);
        if (penalty > 0) {
            SafeTransferLib.safeTransferETH(blastFeeVault, penalty);
        }

        return userEther;
    }
    /**
     * @notice Calculates the claim rate in basis points based on gasSeconds, gasToClaim
     * @param gasSecondsToConsume The amount of gas seconds to consume
     * @param gasToClaim The amount of gas to claim
     * @return claimRate The calculated claim rate in basis points
     * @return gasSecondsToConsume The normalized gas seconds to consume (<= gasSecondsToConsume)
     */
    function getClaimRateBps(uint256 gasSecondsToConsume, uint256 gasToClaim) public view returns (uint256, uint256) {
        uint256 secondsStaked = gasSecondsToConsume / gasToClaim;
        if (secondsStaked < baseGasSeconds) {
            return (zeroClaimRate, 0);
        }
        if (secondsStaked >= ceilGasSeconds) {
            uint256 gasToConsumeNormalized = gasToClaim * ceilGasSeconds;
            return (ceilClaimRate, gasToConsumeNormalized);
        }

        uint256 rateDiff = ceilClaimRate - baseClaimRate;
        uint256 secondsDiff = ceilGasSeconds - baseGasSeconds;
        uint256 secondsStakedDiff = secondsStaked - baseGasSeconds;
        uint256 additionalClaimRate = rateDiff * secondsStakedDiff / secondsDiff;
        uint256 claimRate = baseClaimRate + additionalClaimRate;
        return (claimRate, gasSecondsToConsume);
    }

    /**
     * @notice Reads the gas parameters for a given user
     * @param user The address of the user
     * @return etherSeconds The integral of ether over time (ether * seconds vested)
     * @return etherBalance The total ether balance for the user
     * @return lastUpdated The last updated timestamp for the user's gas parameters
     * @return mode The current gas mode for the user
     */
     function readGasParams(address user) public view returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode mode) {
        bytes32 paramsHash = keccak256(abi.encodePacked(user, "parameters"));
        bytes32 packedParams;
        // read params
        assembly {
            packedParams := sload(paramsHash)
        }

        // unpack params
        // - The first byte (most significant byte) represents the mode
        // - The next 12 bytes represent the etherBalance
        // - The following 15 bytes represent the etherSeconds
        // - The last 4 bytes (least significant bytes) represent the lastUpdated timestamp
        mode         = GasMode(uint8(packedParams[0]));
        etherBalance = uint256((packedParams << (1             * 8)) >> ((32 - 12) * 8));
        etherSeconds = uint256((packedParams << ((1 + 12)      * 8)) >> ((32 - 15) * 8));
        lastUpdated  = uint256((packedParams << ((1 + 12 + 15) * 8)) >> ((32 -  4) * 8));

        // update ether seconds
        etherSeconds = etherSeconds + etherBalance * (block.timestamp - lastUpdated);
    }

    /**
     * @notice Updates the gas parameters for a given contract address
     * @param contractAddress The address of the contract
     * @param etherSeconds The integral of ether over time (ether * seconds vested)
     * @param etherBalance The total ether balance for the contract
     */
    function _updateGasParams(address contractAddress, uint256 etherSeconds, uint256 etherBalance, GasMode mode) internal {
        if (
            etherBalance >= 1 << (12 * 8) ||
            etherSeconds >= 1 << (15 * 8)
        ) {
            revert("Unexpected packing issue due to overflow");
        }

        uint256 updatedTimestamp = block.timestamp; // Known to fit in 4 bytes

        bytes32 paramsHash = keccak256(abi.encodePacked(contractAddress, "parameters"));
        bytes32 packedParams;
        packedParams = (
            (bytes32(uint256(mode)) << ((12 + 15 + 4) * 8)) | // Shift mode to the most significant byte
            (bytes32(etherBalance)  << ((15 + 4) * 8))      | // Shift etherBalance to start after 1 byte of mode
            (bytes32(etherSeconds)  << (4 * 8))             | // Shift etherSeconds to start after mode and etherBalance
            bytes32(updatedTimestamp)                         // Keep updatedTimestamp in the least significant bytes
        );

        assembly {
            sstore(paramsHash, packedParams)
        }
    }
}
