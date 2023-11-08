pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./NodeDriver.sol";
import "../ownership/Ownable.sol";
import "./ConstantsManager.sol";

contract SFCState is Initializable, Ownable {
    using SafeMath for uint256;

    NodeDriverAuth internal node;

    uint256 public currentSealedEpoch;
    uint256 public totalStake;
    uint256 public totalActiveStake;
    uint256 public totalSlashedStake;

    struct EpochSnapshot {
        mapping(uint256 => uint256) receivedStake;
        mapping(uint256 => uint256) accumulatedRewardPerToken;
        mapping(uint256 => uint256) accumulatedUptime;
        mapping(uint256 => uint256) accumulatedOriginatedTxsFee;
        mapping(uint256 => uint256) offlineTime;
        mapping(uint256 => uint256) offlineBlocks;

        uint256[] validatorIDs;

        uint256 endTime;
        uint256 epochFee;
        uint256 totalBaseRewardWeight;
        uint256 totalTxRewardWeight;
        uint256 baseRewardPerSecond;
        uint256 totalStake;
        uint256 totalSupply;
    }

    uint256 private erased0;
    uint256 public totalSupply;
    mapping(uint256 => EpochSnapshot) public getEpochSnapshot;

    uint256 private erased1;
    uint256 private erased2;

    mapping(uint256 => uint256) public slashingRefundRatio; // validator ID -> (slashing refund ratio)

    address public stakeTokenizerAddress;

    uint256 private erased3;
    uint256 private erased4;
    uint256 public minGasPrice;

    address public treasuryAddress;

    DelegationHandler internal delegationHandler;

    ValidatorHandler internal validatorHandler;

    address internal libAddress;

    ConstantsManager internal c;

    address public voteBookAddress;

    address internal sftmFinalizer;
}
