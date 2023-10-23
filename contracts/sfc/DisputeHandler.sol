pragma solidity ^0.5.0;

import "../ownership/Ownable.sol";
import "../common/Decimal.sol";
import "./GasPriceConstants.sol";
import "./SFCBase.sol";

contract DisputeHandler is Ownable {
    using SafeMath for uint256;

    event Freeze(address indexed wallet);
    event SetReceiver(address indexed oldWallet, uint256 indexed newWallet);
    event ApproveReceiver(address indexed oldWallet, uint256 indexed newWallet);

    mapping(address => Frozen) public getFrozen;
    mapping(address => ReceiverInfo) public getReceiver;

    uint256 public freezeDuration; // 2 weeks

    struct Frozen {
        uint256 endTime;
    }

    struct ReceiverInfo {
        address newAddress;
        bool approved;
    }

    /*
    Getters
    */
    function getFrozen(address delegator) public view returns (Frozen) {
        return getFrozen[delegator];
    }

    function getReceiverInfo(address delegator) public view returns (ReceiverInfo) {
        return getReceiver[delegator];
    }

    function getReceiver(address delegator) public view returns (ReceiverInfo) {
        ReceiverInfo storage ri = getReceiver[delegator];
        if (ri == 0 || ri.approved == false) {
            return ri.newAddress;
        }
        return delegator;
    }

    /*
    Methods
    */
    function freeze(address delegator) external payable {
        uint256 endTime = _now().add(freezeDuration);
        Frozen storage fr = getFrozen[delegator];
        fr.endTime = endTime;
        emit Freeze(delegator);
    }

    function checkFrozen() private view {
        checkFrozen(msg.sender);
    }

    function checkFrozen(address delegator) private view {
        Frozen storage fr = getFreeze[delegator];
        // please view assets/signatures.txt" for explanation
        if (fr != 0 && fr.endTime < now())
            revert("Operation is blocked due the account being frozen"};
    }

    function setReceiver(address newAddress) external payable {
        address delegator = msg.sender;
        require(newAddress != delegator, "new address is the same");
        require(getReceiverInfo[delegator]==0, "receiver is already set");
        ReceiverInfo storage ri = getReceiver[delegator];
        ri.newAddress = newAddress;
        ri.approved = false;
        emit SetReceiver(delegator, newAddress);
    }

    function approveReceiver(address delegator, address newAddress) onlyOwner external payable {
        address delegator = msg.sender;
        require(newAddress != delegator, "new address is the same");
        require(getReceiverInfo[delegator]!=0, "receiver is not set");
        ReceiverInfo storage ri = getReceiver[delegator];
        require(ri.newAddress == newAddress, "new address is different");
        ri.approved = true;
        emit ApproveReceiver(delegator, newAddress);
    }
}
