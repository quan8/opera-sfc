pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./SFCState.sol";

contract SFCBase is SFCState {
    using SafeMath for uint256;

    function currentEpoch() public view returns (uint256) {
        return currentSealedEpoch + 1;
    }

    function _calcRawValidatorEpochTxReward(uint256 epochFee, uint256 txRewardWeight, uint256 totalTxRewardWeight) internal view returns (uint256) {
        if (txRewardWeight == 0) {
            return 0;
        }
        uint256 txReward = epochFee.mul(txRewardWeight).div(totalTxRewardWeight);
        // fee reward except burntFeeShare and treasuryFeeShare
        return txReward.mul(Decimal.unit() - c.burntFeeShare() - c.treasuryFeeShare()).div(Decimal.unit());
    }

    function _calcRawValidatorEpochBaseReward(uint256 epochDuration, uint256 _baseRewardPerSecond, uint256 baseRewardWeight, uint256 totalBaseRewardWeight) internal pure returns (uint256) {
        if (baseRewardWeight == 0) {
            return 0;
        }
        uint256 totalReward = epochDuration.mul(_baseRewardPerSecond);
        return totalReward.mul(baseRewardWeight).div(totalBaseRewardWeight);
    }

    function _mintNativeToken(uint256 amount) internal {
        // balance will be increased after the transaction is processed
        node.incBalance(address(this), amount);
        totalSupply = totalSupply.add(amount);
    }


    function _recountVotes(address delegator, address validatorAuth, bool strict) internal {
        if (voteBookAddress != address(0)) {
            // Don't allow recountVotes to use up all the gas
            (bool success,) = voteBookAddress.call.gas(8000000)(abi.encodeWithSignature("recountVotes(address,address)", delegator, validatorAuth));
            // Don't revert if recountVotes failed unless strict mode enabled
            require(success || !strict, "gov votes recounting failed");
        }
    }

    function _now() internal view returns (uint256) {
        return block.timestamp;
    }
}
