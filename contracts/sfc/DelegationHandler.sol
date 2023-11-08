pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "../ownership/Ownable.sol";
import "./SFCState.sol";

contract DelegationHandler is Ownable {
    using SafeMath for uint256;

    event RequestedRedelegation(address indexed delegator, uint256 indexed fromValidatorID, uint256 amount);
    event Redelegated(address indexed delegator, uint256 indexed fromValidatorID, uint256 indexed toValidatorID, uint256 amount);

    struct Rewards {
        uint256 lockupExtraReward;
        uint256 lockupBaseReward;
        uint256 unlockedReward;
    }

    mapping(address => mapping(uint256 => Rewards)) internal _rewardsStash; // addr, validatorID -> Rewards

    mapping(address => mapping(uint256 => uint256)) public stashedRewardsUntilEpoch;

    struct WithdrawalRequest {
        uint256 epoch;
        uint256 time;

        uint256 amount;
    }

    mapping(address => mapping(uint256 => mapping(uint256 => WithdrawalRequest))) public getWithdrawalRequest;

    struct LockedDelegation {
        uint256 lockedStake;
        uint256 fromEpoch;
        uint256 endTime;
        uint256 duration;
    }

    mapping(address => mapping(uint256 => uint256)) public getStake;

    mapping(address => mapping(uint256 => LockedDelegation)) public getLockupInfo;

    mapping(address => mapping(uint256 => Rewards)) public getStashedLockupRewards;

    // New storage variables, no variables in SFCBase and SFCLib
    // so we are probably safe
    struct Penalty {
        uint256 penalty;
        uint256 penaltyEnd;
        uint256 amountLockedForPenalty;//locked stake at the moment of the snapshot
    }
    struct RedelegationRequest {
        uint256 time;
        uint256 prevLockDuration;
        uint256 prevLockEndTime;
        uint256 amount;
        Penalty[] penalties;
    }
    mapping(address => mapping(uint256 => Penalty[])) public getPenaltyInfo;
    mapping(address => mapping(uint256 => RedelegationRequest)) public getRedelegationRequest;
    function sumRewards(Rewards memory a, Rewards memory b) internal pure returns (Rewards memory) {
        return Rewards(a.lockupExtraReward.add(b.lockupExtraReward), a.lockupBaseReward.add(b.lockupBaseReward), a.unlockedReward.add(b.unlockedReward));
    }

    function sumRewards(Rewards memory a, Rewards memory b, Rewards memory c) internal pure returns (Rewards memory) {
        return sumRewards(sumRewards(a, b), c);
    }

    function _scaleLockupReward(uint256 fullReward, uint256 lockupDuration) internal view returns (Rewards memory reward) {
        reward = Rewards(0, 0, 0);
        uint256 unlockedRewardRatio = c.unlockedRewardRatio();
        if (lockupDuration != 0) {
            uint256 maxLockupExtraRatio = Decimal.unit() - unlockedRewardRatio;
            uint256 lockupExtraRatio = maxLockupExtraRatio.mul(lockupDuration).div(c.maxLockupDuration());
            uint256 totalScaledReward = fullReward.mul(unlockedRewardRatio + lockupExtraRatio).div(Decimal.unit());
            reward.lockupBaseReward = fullReward.mul(unlockedRewardRatio).div(Decimal.unit());
            reward.lockupExtraReward = totalScaledReward - reward.lockupBaseReward;
        } else {
            reward.unlockedReward = fullReward.mul(unlockedRewardRatio).div(Decimal.unit());
        }
        return reward;
    }

    // At the request phase we undelegate and unlock (no penalties applied) tokens from the fromValidator
    // we do not specify the toValidator because of the delay, if toValidator will cease to exist
    // during this period, user's funds will be stuck, for this reason we allow user to choose
    // the toValidator after the redelegation period
    function requestRedelegation(uint256 fromValidatorID, uint256 amount) external {
        address delegator = msg.sender;
        RedelegationRequest storage rdRequest = getRedelegationRequest[delegator][fromValidatorID];
        // fail early
        require(rdRequest.time == 0, "has an active request");

        LockedDelegation storage fromLock = getLockupInfo[delegator][fromValidatorID];
        // we allow only locked tokens redelegation, so user won't suffer penalties when undelegating
        // and unlocking with standard functions, if the user wants to redelegate his unlocked stake
        // he is free to use undelegate() function
        require(amount > 0, "zero amount");
        require(amount <= getLockedStake(delegator, fromValidatorID), "not enough locked stake");
        require(_checkAllowedToWithdraw(delegator, fromValidatorID), "outstanding sFTM balance");

        _stashRewards(delegator, fromValidatorID);
        _rawUndelegate(delegator, fromValidatorID, amount, true);

        // stash accumulated penalties and update stashed lock rewards
        // if the user has an empty penalties array (never relocked)
        refreshPenalties(delegator, fromValidatorID);
        Penalty[] storage penalties = getPenaltyInfo[delegator][fromValidatorID];
        uint256 penalty = _popDelegationUnlockPenalty(delegator, fromValidatorID, fromLock.lockedStake, fromLock.lockedStake);
        penalties.push(Penalty(penalty, fromLock.endTime, fromLock.lockedStake));
        // save prev lock info and set a timestamp
        // later we transfer lock info from val#1 to val#2,
        // expect that val#2 already has locks from the user
        rdRequest.time = _now() + c.redelegationPeriodTime();
        rdRequest.prevLockDuration = fromLock.duration;
        rdRequest.prevLockEndTime = fromLock.endTime;
        rdRequest.amount = amount;
        rdRequest.penalties = penalties;
        // update fromValidator lockup info
        if(fromLock.lockedStake <= amount) {
            delete getPenaltyInfo[delegator][fromValidatorID];
            delete getLockupInfo[delegator][fromValidatorID];
        } else {
            uint256 fromLockedStake = fromLock.lockedStake;
            // reduce remaining penalty and lock according to the redelegation amount
            getPenaltyInfo._getStashedPenaltyForUnlock(delegator, fromValidatorID, amount);
            fromLock.lockedStake = fromLockedStake.sub(amount);
        }
        emit UnlockedStake(delegator, fromValidatorID, amount, 0);
        emit RequestedRedelegation(delegator, fromValidatorID, amount);
    }

    // execute the redelegation, if the toValidator do not exist or has reached his limit,
    // the user will have to specify another one, we assume that there are at least one active validator
    // that will accept the redelegation (e.g. the validator we redelegated from) so the user's tokens  won't get stuck
    function executeRedelegation(uint256 fromValidatorID, uint256 toValidatorID) external {
        address delegator = msg.sender;
        RedelegationRequest memory rdRequest = getRedelegationRequest[delegator][fromValidatorID];

        require(rdRequest.time != 0, "redelegation request not found");
        require(rdRequest.time <= _now(), "not enough time passed");

        _stashRewards(delegator, fromValidatorID);
        _delegate(delegator, toValidatorID, rdRequest.amount);

        LockedDelegation storage toLock = getLockupInfo[delegator][toValidatorID];
        // can't redelegate to valiator where user has a lock that will end earlier than his previous one
        // if delegator has previous lock for this validator, just increase the amount
        if(toLock.lockedStake != 0) {
            uint256 toLockedStake = toLock.lockedStake;
            toLock.lockedStake = toLockedStake.add(rdRequest.amount);

            emit LockedUpStake(delegator, toValidatorID, toLock.duration, rdRequest.amount);
        } else {
            // create a new locka with previous params
            address validatorAddr = getValidator[toValidatorID].auth;
            if (delegator != validatorAddr) {
                require(
                    getLockupInfo[validatorAddr][toValidatorID].endTime >= rdRequest.prevLockEndTime,
                    "validator lockup period will end earlier"
                );
            }

            //_stashRewards(delegator, toValidatorID);
            toLock.lockedStake = toLock.lockedStake.add(rdRequest.amount);
            toLock.fromEpoch = currentEpoch();
            toLock.endTime = rdRequest.prevLockEndTime;
            toLock.duration = rdRequest.prevLockDuration;

            emit LockedUpStake(delegator, toValidatorID, rdRequest.prevLockDuration, rdRequest.amount);
        }
        // move penalties
        refreshPenalties(delegator, toValidatorID);
        Penalty[] memory result = StakingHelper._splitPenalties(rdRequest.penalties, rdRequest.amount);
        getPenaltyInfo._movePenalties(delegator, toValidatorID, result);

        delete getRedelegationRequest[delegator][fromValidatorID];
        emit Redelegated(delegator, fromValidatorID, toValidatorID, rdRequest.amount);
    }

    function getLockedStake(address delegator, uint256 toValidatorID) public view returns (uint256) {
        if (!isLockedUp(delegator, toValidatorID)) {
            return 0;
        }
        return getLockupInfo[delegator][toValidatorID].lockedStake;
    }

    function isLockedUp(address delegator, uint256 toValidatorID) view public returns (bool) {
        return getLockupInfo[delegator][toValidatorID].endTime != 0 && getLockupInfo[delegator][toValidatorID].lockedStake != 0 && _now() <= getLockupInfo[delegator][toValidatorID].endTime;
    }

    function rewardsStash(address delegator, uint256 validatorID) public view returns (uint256) {
        Rewards memory stash = _rewardsStash[delegator][validatorID];
        return stash.lockupBaseReward.add(stash.lockupExtraReward).add(stash.unlockedReward);
    }

    function _delegate(address delegator, uint256 toValidatorID, uint256 amount) internal {
        require(_validatorExists(toValidatorID), "validator doesn't exist");
        require(getValidator[toValidatorID].status == OK_STATUS, "validator isn't active");
        _rawDelegate(delegator, toValidatorID, amount, true);
        require(_checkDelegatedStakeLimit(toValidatorID), "validator's delegations limit is exceeded");
    }

    function _rawDelegate(address delegator, uint256 toValidatorID, uint256 amount, bool strict) internal {
        require(amount > 0, "zero amount");

        _stashRewards(delegator, toValidatorID);

        getStake[delegator][toValidatorID] = getStake[delegator][toValidatorID].add(amount);
        uint256 origStake = getValidator[toValidatorID].receivedStake;
        getValidator[toValidatorID].receivedStake = origStake.add(amount);
        totalStake = totalStake.add(amount);
        if (getValidator[toValidatorID].status == OK_STATUS) {
            totalActiveStake = totalActiveStake.add(amount);
        }

        _syncValidator(toValidatorID, origStake == 0);

        emit Delegated(delegator, toValidatorID, amount);

        _recountVotes(delegator, getValidator[toValidatorID].auth, strict);
    }


    function _rawUndelegate(address delegator, uint256 toValidatorID, uint256 amount, bool strict) internal {
        getStake[delegator][toValidatorID] = getStake[delegator][toValidatorID].sub(amount);
        getValidator[toValidatorID].receivedStake = getValidator[toValidatorID].receivedStake.sub(amount);
        totalStake = totalStake.sub(amount);
        if (getValidator[toValidatorID].status == OK_STATUS) {
            totalActiveStake = totalActiveStake.sub(amount);
        }

        uint256 selfStakeAfterwards = getSelfStake(toValidatorID);
        if (selfStakeAfterwards != 0) {
            if (getValidator[toValidatorID].status == OK_STATUS) {
                require(selfStakeAfterwards >= c.minSelfStake(), "insufficient self-stake");
                require(_checkDelegatedStakeLimit(toValidatorID), "validator's delegations limit is exceeded");
            }
        } else {
            _setValidatorDeactivated(toValidatorID, WITHDRAWN_BIT);
        }

        _recountVotes(delegator, getValidator[toValidatorID].auth, strict);
    }


    function _withdraw(address payable delegator, uint256 toValidatorID, uint256 wrID, address payable receiver) private {
        WithdrawalRequest memory request = getWithdrawalRequest[delegator][toValidatorID][wrID];
        require(request.epoch != 0, "request doesn't exist");
        require(_checkAllowedToWithdraw(delegator, toValidatorID), "outstanding sFTM balance");

        uint256 requestTime = request.time;
        uint256 requestEpoch = request.epoch;
        if (getValidator[toValidatorID].deactivatedTime != 0 && getValidator[toValidatorID].deactivatedTime < requestTime) {
            requestTime = getValidator[toValidatorID].deactivatedTime;
            requestEpoch = getValidator[toValidatorID].deactivatedEpoch;
        }

        require(_now() >= requestTime + c.withdrawalPeriodTime(), "not enough time passed");
        require(currentEpoch() >= requestEpoch + c.withdrawalPeriodEpochs(), "not enough epochs passed");

        uint256 amount = getWithdrawalRequest[delegator][toValidatorID][wrID].amount;
        bool isCheater = isSlashed(toValidatorID);
        uint256 penalty = getSlashingPenalty(amount, isCheater, slashingRefundRatio[toValidatorID]);
        delete getWithdrawalRequest[delegator][toValidatorID][wrID];

        totalSlashedStake += penalty;
        require(amount > penalty, "stake is fully slashed");
        // It's important that we transfer after erasing (protection against Re-Entrancy)
        (bool sent,) = receiver.call.value(amount.sub(penalty))("");
        require(sent, "Failed to send FTM");
        _burnFTM(penalty);

        emit Withdrawn(delegator, toValidatorID, wrID, amount);
    }

    function _isLockedUpAtEpoch(address delegator, uint256 toValidatorID, uint256 epoch) internal view returns (bool) {
        return getLockupInfo[delegator][toValidatorID].fromEpoch <= epoch && getEpochSnapshot[epoch].endTime <= getLockupInfo[delegator][toValidatorID].endTime;
    }

    function getUnlockedStake(address delegator, uint256 toValidatorID) public view returns (uint256) {
        if (!isLockedUp(delegator, toValidatorID)) {
            return getStake[delegator][toValidatorID];
        }
        return getStake[delegator][toValidatorID].sub(getLockupInfo[delegator][toValidatorID].lockedStake);
    }

    function _lockStake(address delegator, uint256 toValidatorID, uint256 lockupDuration, uint256 amount) internal {
        require(amount <= getUnlockedStake(delegator, toValidatorID), "not enough stake");
        require(getValidator[toValidatorID].status == OK_STATUS, "validator isn't active");

        require(lockupDuration >= c.minLockupDuration() && lockupDuration <= c.maxLockupDuration(), "incorrect duration");
        uint256 endTime = _now().add(lockupDuration);
        address validatorAddr = getValidator[toValidatorID].auth;
        if (delegator != validatorAddr) {
            require(getLockupInfo[validatorAddr][toValidatorID].endTime >= endTime, "validator lockup period will end earlier");
        }

        _stashRewards(delegator, toValidatorID);

        // check lockup duration after _stashRewards, which has erased previous lockup if it has unlocked already
        LockedDelegation storage ld = getLockupInfo[delegator][toValidatorID];
        require(lockupDuration >= ld.duration, "lockup duration cannot decrease");

        ld.lockedStake = ld.lockedStake.add(amount);
        ld.fromEpoch = currentEpoch();
        ld.endTime = endTime;
        ld.duration = lockupDuration;

        emit LockedUpStake(delegator, toValidatorID, lockupDuration, amount);
    }
}
