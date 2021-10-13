// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '../interfaces/IP2EToken.sol';
import '../core/SafeOwnable.sol';

contract TokenLocker is ERC20 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event NewReceiver(address receiver, uint sendAmount, uint totalReleaseAmount, uint lastReleaseAt);
    event ReleaseToken(address receiver, uint releaseAmount, uint nextReleaseAmount, uint nextReleaseBlockNum);

    uint256 public immutable FIRST_LOCK_SECONDS;
    uint256 public immutable LOCK_PERIOD;
    uint256 public immutable LOCK_PERIOD_NUM;

    IERC20 public immutable token;
    uint256 public totalLockAmount;

    struct ReleaseInfo {
        address receiver;               //who will receive the release token
        uint256 totalReleaseAmount;     //the amount of the token total released for the receiver;
        bool firstUnlock;               //first unlock already done
        uint256 lastReleaseAt;          //the last seconds the the receiver get the released token
        uint256 alreadyReleasedAmount;  //the amount the token already released for the reciever
    }
    mapping(address => ReleaseInfo) public receivers;

    constructor(
        string memory _name, string memory _symbol, IERC20 _token, uint256 _firstLockSeconds, uint256 _lockPeriod, uint256 _lockPeriodNum
    ) ERC20(_name, _symbol) {
        require(address(_token) != address(0), "token address is zero");
        token = _token;
        FIRST_LOCK_SECONDS = _firstLockSeconds;
        LOCK_PERIOD = _lockPeriod;
        LOCK_PERIOD_NUM = _lockPeriodNum;
    }

    function addReceiver(address _receiver, uint256 _amount) external {
        require(_receiver != address(0), "receiver address is zero");
        require(_amount > 0, "release amount is zero");
        totalLockAmount = totalLockAmount.add(_amount);
        ReleaseInfo storage receiver = receivers[_receiver];
        uint totalReleaseAmount = receiver.totalReleaseAmount.sub(receiver.alreadyReleasedAmount).add(_amount);
        receiver.receiver = _receiver;
        receiver.totalReleaseAmount = totalReleaseAmount;
        receiver.firstUnlock = false;
        receiver.lastReleaseAt = block.timestamp;
        receiver.alreadyReleasedAmount = 0;
        token.safeTransferFrom(msg.sender, address(this), _amount);
        _mint(_receiver, _amount);
        emit NewReceiver(_receiver, _amount, totalReleaseAmount, receiver.lastReleaseAt);
    }

    //response1: the timestamp for next release
    //response2: the amount for next release
    //response3: the total amount already released
    //response4: the remain amount for the receiver to release
    function getReleaseInfo(address _receiver) public view returns (uint256 nextReleaseAt, uint256 nextReleaseAmount, uint256 alreadyReleaseAmount, uint256 remainReleaseAmount) {
        ReleaseInfo storage receiver = receivers[_receiver];
        require(_receiver != address(0), "receiver not exist");
        if (_receiver != receiver.receiver) {
            return (0, 0, 0, 0);
        }
        if (!receiver.firstUnlock) {
            nextReleaseAt = receiver.lastReleaseAt + FIRST_LOCK_SECONDS;
        } else {
            nextReleaseAt = receiver.lastReleaseAt + LOCK_PERIOD;
        }
        nextReleaseAmount = receiver.totalReleaseAmount.div(LOCK_PERIOD_NUM);
        alreadyReleaseAmount = receiver.alreadyReleasedAmount;
        remainReleaseAmount = receiver.totalReleaseAmount.sub(receiver.alreadyReleasedAmount);
        if (nextReleaseAmount > remainReleaseAmount) {
            nextReleaseAmount = remainReleaseAmount;
        }
    }

    function claim(address _receiver) external {
        (uint nextReleaseSeconds, uint nextReleaseAmount, , ) = getReleaseInfo(_receiver);
        require(block.timestamp >= nextReleaseSeconds, "not the right time");
        require(nextReleaseAmount > 0, "already released all");
        ReleaseInfo storage receiver = receivers[_receiver];
        if (!receiver.firstUnlock) {
            receiver.firstUnlock = true; 
        }
        receiver.lastReleaseAt = nextReleaseSeconds;
        receiver.alreadyReleasedAmount = receiver.alreadyReleasedAmount.add(nextReleaseAmount);
        totalLockAmount = totalLockAmount.sub(nextReleaseAmount);
        token.safeTransfer(receiver.receiver, nextReleaseAmount);
        _burn(_receiver, nextReleaseAmount);
        (uint nextNextReleaseSeconds, uint nextNextReleaseAmount, , ) = getReleaseInfo(_receiver);
        emit ReleaseToken(_receiver, nextReleaseAmount, nextNextReleaseSeconds, nextNextReleaseAmount);
    }
}
