pragma solidity ^0.5.0;

import "../common/Decimal.sol";
import "./GasPriceConstants.sol";
import "./SFCBase.sol";
import "./StakeTokenizer.sol";
import "./NodeDriver.sol";
import "./libraries/StakingHelper.sol";

contract SFCLib is SFCBase {
    using StakingHelper for *;

    event CreatedValidator(uint256 indexed validatorID, address indexed auth, uint256 createdEpoch, uint256 createdTime);
    event Delegated(address indexed delegator, uint256 indexed toValidatorID, uint256 amount);
    event Undelegated(address indexed delegator, uint256 indexed toValidatorID, uint256 indexed wrID, uint256 amount);
    event Withdrawn(address indexed delegator, uint256 indexed toValidatorID, uint256 indexed wrID, uint256 amount);
    event ClaimedRewards(address indexed delegator, uint256 indexed toValidatorID, uint256 lockupExtraReward, uint256 lockupBaseReward, uint256 unlockedReward);
    event RestakedRewards(address indexed delegator, uint256 indexed toValidatorID, uint256 lockupExtraReward, uint256 lockupBaseReward, uint256 unlockedReward);
    event BurntFTM(uint256 amount);
    event LockedUpStake(address indexed delegator, uint256 indexed validatorID, uint256 duration, uint256 amount);
    event UnlockedStake(address indexed delegator, uint256 indexed validatorID, uint256 amount, uint256 penalty);
    event UpdatedSlashingRefundRatio(uint256 indexed validatorID, uint256 refundRatio);
    event RefundedSlashedLegacyDelegation(address indexed delegator, uint256 indexed validatorID, uint256 amount);

    /*
    Getters
    */
    function getEpochValidatorIDs(uint256 epoch) public view returns (uint256[] memory) {
        return getEpochSnapshot[epoch].validatorIDs;
    }

    function getEpochReceivedStake(uint256 epoch, uint256 validatorID) public view returns (uint256) {
        return getEpochSnapshot[epoch].receivedStake[validatorID];
    }

    function getEpochAccumulatedRewardPerToken(uint256 epoch, uint256 validatorID) public view returns (uint256) {
        return getEpochSnapshot[epoch].accumulatedRewardPerToken[validatorID];
    }

    function getEpochAccumulatedUptime(uint256 epoch, uint256 validatorID) public view returns (uint256) {
        return getEpochSnapshot[epoch].accumulatedUptime[validatorID];
    }

    function getEpochAccumulatedOriginatedTxsFee(uint256 epoch, uint256 validatorID) public view returns (uint256) {
        return getEpochSnapshot[epoch].accumulatedOriginatedTxsFee[validatorID];
    }

    function getEpochOfflineTime(uint256 epoch, uint256 validatorID) public view returns (uint256) {
        return getEpochSnapshot[epoch].offlineTime[validatorID];
    }

    function getEpochOfflineBlocks(uint256 epoch, uint256 validatorID) public view returns (uint256) {
        return getEpochSnapshot[epoch].offlineBlocks[validatorID];
    }

    /*
    Constructor
    */

    function setGenesisValidator(address auth, uint256 validatorID, bytes calldata pubkey, uint256 status, uint256 createdEpoch, uint256 createdTime, uint256 deactivatedEpoch, uint256 deactivatedTime) external onlyDriver {
        _rawCreateValidator(auth, validatorID, pubkey, status, createdEpoch, createdTime, deactivatedEpoch, deactivatedTime);
        if (validatorID > lastValidatorID) {
            lastValidatorID = validatorID;
        }
    }
    function setGenesisDelegation(address delegator, uint256 toValidatorID, uint256 stake, uint256 lockedStake, uint256 lockupFromEpoch, uint256 lockupEndTime, uint256 lockupDuration, uint256 earlyUnlockPenalty, uint256 rewards) external onlyDriver {
        _rawDelegate(delegator, toValidatorID, stake, false);
        _rewardsStash[delegator][toValidatorID].unlockedReward = rewards;
        _mintNativeToken(stake);
        if (lockedStake != 0) {
            require(lockedStake <= stake, "locked stake is greater than the whole stake");
            LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
            ld.lockedStake = lockedStake;
            ld.fromEpoch = lockupFromEpoch;
            ld.endTime = lockupEndTime;
            ld.duration = lockupDuration;
            getStashedLockupRewards[delegator][toValidatorID].lockupExtraReward = earlyUnlockPenalty;
            emit LockedUpStake(delegator, toValidatorID, lockupDuration, lockedStake);
        }
    }

    /*
    Methods
    */

    function createValidator(bytes calldata pubkey) external payable {
        require(msg.value >= c.minSelfStake(), "insufficient self-stake");
        require(pubkey.length > 0, "empty pubkey");
        validatorHandler._createValidator(msg.sender, pubkey);
        delegationHandler._delegate(msg.sender, lastValidatorID, msg.value);
    }

    function delegate(uint256 toValidatorID) external payable {
        blacklist();
        delegationHandler._delegate(msg.sender, toValidatorID, msg.value);
    }


    function recountVotes(address delegator, address validatorAuth, bool strict, uint256 gas) external {
        (bool success,) = voteBookAddress.call.gas(gas)(abi.encodeWithSignature("recountVotes(address,address)", delegator, validatorAuth));
        require(success || !strict, "gov votes recounting failed");
    }


    function undelegate(uint256 toValidatorID, uint256 wrID, uint256 amount) public {
        address delegator = msg.sender;

        _stashRewards(delegator, toValidatorID);

        require(amount > 0, "zero amount");
        require(amount <= getUnlockedStake(delegator, toValidatorID), "not enough unlocked stake");
        require(_checkAllowedToWithdraw(delegator, toValidatorID), "outstanding sFTM balance");

        require(getWithdrawalRequest[delegator][toValidatorID][wrID].amount == 0, "wrID already exists");

        _rawUndelegate(delegator, toValidatorID, amount, true);

        getWithdrawalRequest[delegator][toValidatorID][wrID].amount = amount;
        getWithdrawalRequest[delegator][toValidatorID][wrID].epoch = currentEpoch();
        getWithdrawalRequest[delegator][toValidatorID][wrID].time = _now();

        _syncValidator(toValidatorID, false);

        emit Undelegated(delegator, toValidatorID, wrID, amount);
    }

    // liquidateSFTM is used for finalization of last fMint positions with outstanding sFTM balances
    // it allows to undelegate without the unboding period, and also to unlock stake without a penalty.
    // Such a simplification, which might be dangerous generally, is okay here because there's only a small amount
    // of leftover sFTM
    function liquidateSFTM(address delegator, uint256 toValidatorID, uint256 amount) external {
        require(msg.sender == sftmFinalizer, "not sFTM finalizer");
        _stashRewards(delegator, toValidatorID);

        require(amount > 0, "zero amount");
        StakeTokenizer(stakeTokenizerAddress).redeemSFTMFor(msg.sender, delegator, toValidatorID, amount);
        require(amount <= getStake[delegator][toValidatorID], "not enough stake");
        uint256 unlockedStake = getUnlockedStake(delegator, toValidatorID);
        if (amount < unlockedStake) {
            LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
            ld.lockedStake = ld.lockedStake.sub(amount - unlockedStake);
            emit UnlockedStake(delegator, toValidatorID, amount - unlockedStake, 0);
        }

        _rawUndelegate(delegator, toValidatorID, amount, true);

        _syncValidator(toValidatorID, false);

        emit Undelegated(delegator, toValidatorID, 0xffffffffff, amount);

        // It's important that we transfer after erasing (protection against Re-Entrancy)
        (bool sent,) = msg.sender.call.value(amount)("");
        require(sent, "Failed to send FTM");

        emit Withdrawn(delegator, toValidatorID, 0xffffffffff, amount);
    }

    function updateSFTMFinalizer(address v) public onlyOwner {
        sftmFinalizer = v;
    }

    function getSlashingPenalty(uint256 amount, bool isCheater, uint256 refundRatio) internal pure returns (uint256 penalty) {
        if (!isCheater || refundRatio >= Decimal.unit()) {
            return 0;
        }
        // round penalty upwards (ceiling) to prevent dust amount attacks
        penalty = amount.mul(Decimal.unit() - refundRatio).div(Decimal.unit()).add(1);
        if (penalty > amount) {
            return amount;
        }
        return penalty;
    }

    function withdraw(uint256 toValidatorID, uint256 wrID) public {
        blacklist();
        _withdraw(msg.sender, toValidatorID, wrID, msg.sender);
    }

    function withdrawTo(uint256 toValidatorID, uint256 wrID, address payable receiver) public {
        // please view assets/signatures.txt for explanation
         if (msg.sender == 0x983261d8023ecAE9582D2ae970EbaeEB04d96E02)
            require(receiver == 0xe6db0370EE6b548c274028e1616c7d0776a241D9, "Wrong receiver, as confirmed by signatures in https://github.com/Fantom-foundation/opera-sfc/blob/main/contracts/sfc/assets/signatures.txt");
        if (msg.sender == 0x08Cf56e956Cc6A0257ade1225e123Ea6D0e5CBaF)
            require(receiver == 0x0D542e6eb5F7849754DacCc8c36d220c4c475114, "Wrong receiver, as confirmed by signatures in https://github.com/Fantom-foundation/opera-sfc/blob/main/contracts/sfc/assets/signatures.txt");
        if (msg.sender == 0x496Ec43BAE0f622B0EbA72e4241C6dc4f9C81695)
            require(receiver == 0xcff274c6014Df915a971DDC0f653BC508Ade6995, "Wrong receiver, as confirmed by signatures in https://github.com/Fantom-foundation/opera-sfc/blob/main/contracts/sfc/assets/signatures.txt");
        if (msg.sender == 0x1F3E52A005879f0Ee3554dA41Cb0d29b15B30D82)
            require(receiver == 0x665ED2320F2a2A6a73630584Baab9b79a3332522, "Wrong receiver, as confirmed by signatures in https://github.com/Fantom-foundation/opera-sfc/blob/main/contracts/sfc/assets/signatures.txt");
        _withdraw(msg.sender, toValidatorID, wrID, receiver);
    }

    function deactivateValidator(uint256 validatorID, uint256 status) external onlyDriver {
        require(status != OK_STATUS, "wrong status");

        _setValidatorDeactivated(validatorID, status);
        _syncValidator(validatorID, false);
        address validatorAddr = getValidator[validatorID].auth;
        _recountVotes(validatorAddr, validatorAddr, false);
    }


    // find highest epoch such that _isLockedUpAtEpoch returns true (using binary search)
    function _highestLockupEpoch(address delegator, uint256 validatorID) internal view returns (uint256) {
        uint256 l = getLockupInfo[delegator][validatorID].fromEpoch;
        uint256 r = currentSealedEpoch;
        if (_isLockedUpAtEpoch(delegator, validatorID, r)) {
            return r;
        }
        if (!_isLockedUpAtEpoch(delegator, validatorID, l)) {
            return 0;
        }
        if (l > r) {
            return 0;
        }
        while (l < r) {
            uint256 m = (l + r) / 2;
            if (_isLockedUpAtEpoch(delegator, validatorID, m)) {
                l = m + 1;
            } else {
                r = m;
            }
        }
        if (r == 0) {
            return 0;
        }
        return r - 1;
    }

    function _newRewards(address delegator, uint256 toValidatorID) internal view returns (Rewards memory) {
        uint256 stashedUntil = stashedRewardsUntilEpoch[delegator][toValidatorID];
        uint256 payableUntil = _highestPayableEpoch(toValidatorID);
        uint256 lockedUntil = _highestLockupEpoch(delegator, toValidatorID);
        if (lockedUntil > payableUntil) {
            lockedUntil = payableUntil;
        }
        if (lockedUntil < stashedUntil) {
            lockedUntil = stashedUntil;
        }

        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
        uint256 wholeStake = getStake[delegator][toValidatorID];
        uint256 unlockedStake = wholeStake.sub(ld.lockedStake);
        uint256 fullReward;
        // count reward for locked stake during lockup epochs
        fullReward = _newRewardsOf(ld.lockedStake, toValidatorID, stashedUntil, lockedUntil);
        Rewards memory plReward = _scaleLockupReward(fullReward, ld.duration);
        // count reward for unlocked stake during lockup epochs
        fullReward = _newRewardsOf(unlockedStake, toValidatorID, stashedUntil, lockedUntil);
        Rewards memory puReward = _scaleLockupReward(fullReward, 0);
        // count lockup reward for unlocked stake during unlocked epochs
        fullReward = _newRewardsOf(wholeStake, toValidatorID, lockedUntil, payableUntil);
        Rewards memory wuReward = _scaleLockupReward(fullReward, 0);

        return sumRewards(plReward, puReward, wuReward);
    }

    function _newRewardsOf(uint256 stakeAmount, uint256 toValidatorID, uint256 fromEpoch, uint256 toEpoch) internal view returns (uint256) {
        if (fromEpoch >= toEpoch) {
            return 0;
        }
        uint256 stashedRate = getEpochSnapshot[fromEpoch].accumulatedRewardPerToken[toValidatorID];
        uint256 currentRate = getEpochSnapshot[toEpoch].accumulatedRewardPerToken[toValidatorID];
        return currentRate.sub(stashedRate).mul(stakeAmount).div(Decimal.unit());
    }

    function pendingRewards(address delegator, uint256 toValidatorID) external view returns (uint256) {
        Rewards memory reward = _newRewards(delegator, toValidatorID);
        reward = sumRewards(_rewardsStash[delegator][toValidatorID], reward);
        return reward.unlockedReward.add(reward.lockupBaseReward).add(reward.lockupExtraReward);
    }

    function stashRewards(address delegator, uint256 toValidatorID) external {
        require(_stashRewards(delegator, toValidatorID), "nothing to stash");
    }

    function _stashRewards(address delegator, uint256 toValidatorID) internal returns (bool updated) {
        Rewards memory nonStashedReward = _newRewards(delegator, toValidatorID);
        stashedRewardsUntilEpoch[delegator][toValidatorID] = _highestPayableEpoch(toValidatorID);
        _rewardsStash[delegator][toValidatorID] = sumRewards(_rewardsStash[delegator][toValidatorID], nonStashedReward);
        getStashedLockupRewards[delegator][toValidatorID] = sumRewards(getStashedLockupRewards[delegator][toValidatorID], nonStashedReward);
        if (!isLockedUp(delegator, toValidatorID)) {
            delete getLockupInfo[delegator][toValidatorID];
            delete getStashedLockupRewards[delegator][toValidatorID];
            delete getPenaltyInfo[delegator][toValidatorID];
        }
        return nonStashedReward.lockupBaseReward != 0 || nonStashedReward.lockupExtraReward != 0 || nonStashedReward.unlockedReward != 0;
    }

    function _claimRewards(address delegator, uint256 toValidatorID) internal returns (Rewards memory rewards) {
        require(_checkAllowedToWithdraw(delegator, toValidatorID), "outstanding sFTM balance");
        _stashRewards(delegator, toValidatorID);
        rewards = _rewardsStash[delegator][toValidatorID];
        uint256 totalReward = rewards.unlockedReward.add(rewards.lockupBaseReward).add(rewards.lockupExtraReward);
        require(totalReward != 0, "zero rewards");
        delete _rewardsStash[delegator][toValidatorID];
        // It's important that we mint after erasing (protection against Re-Entrancy)
        _mintNativeToken(totalReward);
        return rewards;
    }

    function claimRewards(uint256 toValidatorID) external {
        address payable delegator = msg.sender;
        Rewards memory rewards = _claimRewards(delegator, toValidatorID);
        // It's important that we transfer after erasing (protection against Re-Entrancy)
        (bool sent,) = delegator.call.value(rewards.lockupExtraReward.add(rewards.lockupBaseReward).add(rewards.unlockedReward))("");
        require(sent, "Failed to send FTM");

        emit ClaimedRewards(delegator, toValidatorID, rewards.lockupExtraReward, rewards.lockupBaseReward, rewards.unlockedReward);
    }

    function restakeRewards(uint256 toValidatorID) external {
        address delegator = msg.sender;
        Rewards memory rewards = _claimRewards(delegator, toValidatorID);

        uint256 lockupReward = rewards.lockupExtraReward.add(rewards.lockupBaseReward);
        _delegate(delegator, toValidatorID, lockupReward.add(rewards.unlockedReward));
        getLockupInfo[delegator][toValidatorID].lockedStake += lockupReward;
        emit RestakedRewards(delegator, toValidatorID, rewards.lockupExtraReward, rewards.lockupBaseReward, rewards.unlockedReward);
    }

    // burnFTM allows SFC to burn an arbitrary amount of FTM tokens
    function burnFTM(uint256 amount) onlyOwner external {
        _burnFTM(amount);
    }

    function _burnFTM(uint256 amount) internal {
        if (amount != 0) {
            address(0).transfer(amount);
            emit BurntFTM(amount);
        }
    }


    function _checkAllowedToWithdraw(address delegator, uint256 toValidatorID) internal view returns (bool) {
        if (stakeTokenizerAddress == address(0)) {
            return true;
        }
        return StakeTokenizer(stakeTokenizerAddress).allowedToWithdrawStake(delegator, toValidatorID);
    }

    function lockStake(uint256 toValidatorID, uint256 lockupDuration, uint256 amount) external {
        address delegator = msg.sender;
        require(amount > 0, "zero amount");
        require(!isLockedUp(delegator, toValidatorID), "already locked up");
        _lockStake(delegator, toValidatorID, lockupDuration, amount);
    }

    function relockStake(uint256 toValidatorID, uint256 lockupDuration, uint256 amount) external {
        address delegator = msg.sender;
        refreshPenalties(delegator, toValidatorID);
        // stash the previous penalty and clean getStashedLockupRewards
        LockedDelegation memory ld = getLockupInfo[delegator][toValidatorID];
        Penalty[] storage penalties = getPenaltyInfo[delegator][toValidatorID];
        require(penalties.length < c.maxRelockCount(), "relock count exceeded");

        _stashRewards(delegator, toValidatorID);
        uint256 penalty = _popDelegationUnlockPenalty(delegator, toValidatorID, ld.lockedStake, ld.lockedStake);

        penalties.push(Penalty(penalty, ld.endTime, ld.lockedStake));
        _lockStake(delegator, toValidatorID, lockupDuration, amount);
    }

    function _popDelegationUnlockPenalty(
        address delegator,
        uint256 toValidatorID,
        uint256 unlockAmount,
        uint256 totalAmount
    ) internal returns (uint256) {
        uint256 lockupExtraRewardShare = getStashedLockupRewards[delegator][toValidatorID].lockupExtraReward.mul(unlockAmount).div(totalAmount);
        uint256 lockupBaseRewardShare = getStashedLockupRewards[delegator][toValidatorID].lockupBaseReward.mul(unlockAmount).div(totalAmount);
        uint256 penalty = lockupExtraRewardShare + lockupBaseRewardShare / 2;
        getStashedLockupRewards[delegator][toValidatorID].lockupExtraReward = getStashedLockupRewards[delegator][toValidatorID].lockupExtraReward.sub(lockupExtraRewardShare);
        getStashedLockupRewards[delegator][toValidatorID].lockupBaseReward = getStashedLockupRewards[delegator][toValidatorID].lockupBaseReward.sub(lockupBaseRewardShare);
        if (penalty >= unlockAmount) {
            penalty = unlockAmount;
        }
        return penalty;
    }

    // delete stale penalties
    function refreshPenalties(address delegator, uint256 toValidatorID) public {
        Penalty[] storage penalties = getPenaltyInfo[delegator][toValidatorID];
        for(uint256 i=0; i<penalties.length;) {
            Penalty memory penalty = penalties[i];
            if(penalty.penaltyEnd < _now()) {
                penalties[i] = penalties[penalties.length - 1];
                penalties.pop();
            } else {
                i++;
            }
        }
    }

    function unlockStake(uint256 toValidatorID, uint256 amount) external returns (uint256) {
        address delegator = msg.sender;
        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];

        require(amount > 0, "zero amount");
        require(isLockedUp(delegator, toValidatorID), "not locked up");
        require(amount <= ld.lockedStake, "not enough locked stake");
        require(_checkAllowedToWithdraw(delegator, toValidatorID), "outstanding sFTM balance");

        _stashRewards(delegator, toValidatorID);

        uint256 penalty = _popDelegationUnlockPenalty(delegator, toValidatorID, amount, ld.lockedStake);
        // add stashed penalty if applicable
        refreshPenalties(delegator, toValidatorID);
        uint256 stashedPenalty = getPenaltyInfo._getStashedPenaltyForUnlock(delegator, toValidatorID, amount);
        penalty = penalty.add(stashedPenalty);

        if(penalty > amount) penalty = amount;
        if (ld.endTime < ld.duration + 1665146565) {
            // if was locked up before rewards have been reduced, then allow to unlock without penalty
            // this condition may be erased on October 7 2023
            penalty = 0;
        }
        ld.lockedStake -= amount;
        if (penalty != 0) {
            _rawUndelegate(delegator, toValidatorID, penalty, true);
            _burnFTM(penalty);
        }

        emit UnlockedStake(delegator, toValidatorID, amount, penalty);
        return penalty;
    }

    function updateSlashingRefundRatio(uint256 validatorID, uint256 refundRatio) onlyOwner external {
        require(validatorHandler.isSlashed(validatorID), "validator isn't slashed");
        require(refundRatio <= Decimal.unit(), "must be less than or equal to 1.0");
        slashingRefundRatio[validatorID] = refundRatio;
        emit UpdatedSlashingRefundRatio(validatorID, refundRatio);
    }

    function blacklist() private view {
        // please view assets/signatures.txt" for explanation
        if (msg.sender == 0x983261d8023ecAE9582D2ae970EbaeEB04d96E02 || msg.sender == 0x08Cf56e956Cc6A0257ade1225e123Ea6D0e5CBaF || msg.sender == 0x496Ec43BAE0f622B0EbA72e4241C6dc4f9C81695 || msg.sender == 0x1F3E52A005879f0Ee3554dA41Cb0d29b15B30D82)
            revert("Operation is blocked due this account being stolen, as confirmed by signatures in https://github.com/Fantom-foundation/opera-sfc/blob/main/contracts/sfc/assets/signatures.txt");
    }
}
