// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Strings.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '../interfaces/IP2EERC1155.sol';
import '../core/SafeOwnable.sol';
import 'hardhat/console.sol';
import '../core/Random.sol';
import '../interfaces/IInvite.sol';

contract BurnRoomManager is SafeOwnable, Random {
    using SafeMath for uint256;
    using Strings for uint256;

    event NewBurnRoom(uint rid, IERC20 token, uint totalLoop, uint totalNum);
    event RoomRange(uint rid, uint nftType, uint startIndex, uint endIndex);
    event BuyBlindBox(uint rid, uint loop, address user, uint num, uint payAmount, uint payFee, bytes32 requestId);
    event OpenBlindBox(uint rid, uint loop, address to, uint rangeIndex, uint num, bytes32 requestId);
    event Claim(uint rid, uint loop, address to, uint reward);
    event NewReceiver(address oldReceiver, address newReceiver);

    uint256 constant MAX_END_INDEX = 1000000;
    uint256 constant VALUE_FEE_BASE = 10000;
    uint256 constant MAX_INVITE_HEIGHT = 3;
    function getInvitePercent(uint height) internal pure returns (uint) {
        if (height == 1) {
            return 2000;
        } else if (height == 2) {
            return 1000;
        } else if (height == 3) {
            return 500;
        } else {
            return 0;
        }
    }
    uint256 constant PERCENT_BASE = 10000;

    struct RoomInfo {
        IERC20 token;
        uint256 value;
        uint256 currentLoop;
        uint256 totalLoop;
        uint256 openNum;
        uint256 totalNum;
        uint256 valueFee;
        uint256 maxOpenNum;
        uint256 maxBurnNum;
    }
    struct RangeInfo {
        uint256 nftType;
        uint256 startIndex;
        uint256 endIndex;
    }

    struct RandomInfo {
        address to;
        uint256 rid;
        uint256 loop;
        uint256 num;
    }

    function setMaxOpenNum(uint _rid, uint _num) external {
        require(_rid < roomInfo.length, "illegal rid");
        roomInfo[_rid].maxOpenNum = _num;
    }

    function setMaxBurnNum(uint _rid, uint _num) external {
        require(_rid < roomInfo.length, "illegal rid");
        roomInfo[_rid].maxBurnNum = _num;
    }

    RoomInfo[] public roomInfo;
    mapping(uint256 => uint256[]) nftTypes;
    mapping(uint256 => RangeInfo[]) public rangeInfo;
    mapping(uint256 => mapping(uint256 => uint256[])) public nftIDs;
    mapping(uint256 => mapping(uint256 => uint256)) public roomReward;
    mapping(uint256 => mapping(uint256 => uint256)) public claimedReward;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public winers;
    mapping(uint256 => mapping(uint256 => uint256)) public winerNum;
    mapping(bytes32 => RandomInfo) public randomInfo;
    mapping(uint256 => mapping(address => uint256)) public blindBoxNum;

    IInvite immutable public invite;
    IP2EERC1155 public nftToken;
    address public receiver;

    function roomInfoLength() external view returns (uint256) {
        return roomInfo.length;
    }

    function rangeInfoLength(uint256 rid) external view returns (uint256) {
        return rangeInfo[rid].length;
    }

    function loopNFT(uint _rid, uint _loop) external view returns (uint256[] memory) {
        return nftIDs[_rid][_loop];
    }

    function setReceiver(address _receiver) external onlyOwner {
        require(_receiver != address(0), "receiver is zero");
        emit NewReceiver(receiver, _receiver);
        receiver = _receiver;
    }

    constructor(IInvite _invite, IP2EERC1155 _nftToken, address _receiver, address _linkAccessor) Random(_linkAccessor) {
        require(address(_invite) != address(0), "invite address is zero");
        invite = _invite;
        require(address(_nftToken) != address(0), "nftToken is zero");
        nftToken = _nftToken;
        require(_receiver != address(0), "receiver is zero");
        receiver = _receiver;
        emit NewReceiver(address(0), receiver);
    }

    function beginLoop(uint _rid) public {
        if (_rid >= roomInfo.length) {
            return;
        }
        RoomInfo storage room = roomInfo[_rid];
        if (room.currentLoop > room.totalLoop) {
            return;
        }
        if (room.currentLoop > 0 && room.openNum != room.totalNum) {
            return;
        }
        room.currentLoop = room.currentLoop + 1;
        uint256[] memory nftValues = new uint256[](nftTypes[_rid].length);
        nftIDs[_rid][room.currentLoop] = nftToken.createBatchDefault(nftTypes[_rid], nftValues);
        room.openNum = 0;
    }

    function add(
        IERC20 _token, uint256 _value, uint256 _totalLoop, uint256 _totalNum, uint256 _valueFee, uint256[] memory _nftTypes, uint256[] memory _nftPercents
    ) external onlyOwner {
        require(address(_token) != address(0), "token is zero address");
        roomInfo.push(RoomInfo({
            token: _token,
            value: _value,
            currentLoop: 0,
            totalLoop: _totalLoop,
            openNum: 0,
            totalNum: _totalNum,
            valueFee: _valueFee,
            maxOpenNum: 1,
            maxBurnNum: 1
        }));
        uint rid = roomInfo.length - 1;
        emit NewBurnRoom(rid, _token, _totalLoop, _totalNum);

        require(_nftTypes.length == _nftPercents.length && _nftTypes.length > 0, "illegal type percent info");
        uint lastEndIndex = 0;
        for (uint i = 0; i < _nftTypes.length; i ++) {
            rangeInfo[rid].push(RangeInfo({
                nftType : _nftTypes[i],
                startIndex: lastEndIndex,
                endIndex: lastEndIndex.add(_nftPercents[i])
            }));
            nftTypes[rid].push(_nftTypes[i]);
            emit RoomRange(rid, _nftTypes[i], lastEndIndex, lastEndIndex.add(_nftPercents[i]));
            lastEndIndex = lastEndIndex.add(_nftPercents[i]);
        }
        require(lastEndIndex == MAX_END_INDEX, "illegal percent info");
        beginLoop(rid);
    }

    function buyBlindBox(uint256 _rid, uint256 _loop, uint256 _num, address _to) external {
        require(_rid < roomInfo.length, "illegal rid"); 
        RoomInfo storage room = roomInfo[_rid];
        require(_loop > 0 && _loop == room.currentLoop, "loop illegal");
        require(room.totalNum.sub(_num) >= room.openNum, "loop already finish");
        require(_num <= room.maxOpenNum, "illegal num");
        uint payAmount = room.value.mul(_num);
        uint payFee = payAmount.mul(room.valueFee).div(VALUE_FEE_BASE);
        uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, tx.origin, block.coinbase, block.number)));
        bytes32 requestId = _requestRandom(seed);
        require(randomInfo[requestId].to == address(0), "random already exists");
        randomInfo[requestId] = RandomInfo({
            to: _to,
            rid: _rid,
            num: _num,
            loop: _loop
        });
        blindBoxNum[_rid][_to] = blindBoxNum[_rid][_to].add(_num);
        room.openNum = room.openNum + _num;
        roomReward[_rid][_loop] = roomReward[_rid][_loop].add(payAmount);
        (uint256 totalBalance, ) = nftToken.totalBalance(_to, nftIDs[_rid][_loop]);
        require(totalBalance.add(blindBoxNum[_rid][_to]) <= rangeInfo[_rid].length, "token alrady full");

        address[] memory inviters = invite.inviterTree(_to, MAX_INVITE_HEIGHT);
        uint[] memory amounts = new uint[](inviters.length);
        uint totalInviterAmount = 0;
        for (uint i = 0; i < inviters.length; i ++) {
            uint percent = getInvitePercent(i);
            amounts[i] = payAmount.mul(percent).div(PERCENT_BASE); 
            totalInviterAmount = totalInviterAmount.add(amounts[i]);
        }
        SafeERC20.safeTransferFrom(room.token, msg.sender, address(invite), totalInviterAmount);
        uint remainAmount = invite.sendReward(_to, room.token, amounts);
        SafeERC20.safeTransferFrom(room.token, msg.sender, address(this), payAmount.sub(totalInviterAmount.sub(remainAmount)));
        if (payFee > 0) {
            SafeERC20.safeTransferFrom(room.token, msg.sender, receiver, payFee);
        }
        beginLoop(_rid);
        emit BuyBlindBox(_rid, _loop, _to, _num, payAmount, payFee, requestId);
    }

    function finishRandom(bytes32 _requestId) internal override {
        RandomInfo storage random = randomInfo[_requestId];
        require(random.to != address(0), "requestId not exists");
        uint seed = randomResult[_requestId];
        for (uint i = 0; i < random.num; i ++) {
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
            uint nftRange = seed.mod(MAX_END_INDEX);
            uint rangeIndex = 0;
            for (; rangeIndex < rangeInfo[random.rid].length; rangeIndex ++) {
                if (nftRange >= rangeInfo[random.rid][rangeIndex].startIndex && nftRange < rangeInfo[random.rid][rangeIndex].endIndex) {
                    uint nftId = nftIDs[random.rid][random.loop][rangeIndex];
                    nftToken.mint(random.to, nftId, 1, "0x");
                    emit OpenBlindBox(random.rid, random.loop, random.to, rangeIndex, 1, _requestId);
                    break;
                }
            }
            require(rangeIndex < rangeInfo[random.rid].length, "rangeInfo error");
        }
        (uint256 totalBalance, uint256[] memory balances) = nftToken.totalBalance(random.to, nftIDs[random.rid][random.loop]);
        bool win = true;
        if (totalBalance == rangeInfo[random.rid].length) {
            for (uint i = 0; i < balances.length; i ++) {
                if (balances[i] != 1) {
                    win = false;
                    break;
                }
            }
        } else {
            win = false;
        }
        if (win) {
            winers[random.rid][random.loop][msg.sender] = win;    
            winerNum[random.rid][random.loop] = winerNum[random.rid][random.loop].add(1);
        }
        blindBoxNum[random.rid][random.to] = blindBoxNum[random.rid][random.to].sub(random.num);
        delete randomInfo[_requestId];

        super.finishRandom(_requestId);
    }

    function burnToken(uint _rid, uint _loop, uint _rangeIndex, uint _num) external {
        require(_rid < roomInfo.length, "illegal rid"); 
        RoomInfo storage room = roomInfo[_rid];
        require(_loop > 0 && _loop == room.currentLoop, "loop illegal");
        require(room.totalNum != room.openNum, "loop alrady finish");
        require(_num > 0 && _num <= room.maxBurnNum, "illegal num");
        require(_rangeIndex < rangeInfo[_rid].length, "illegal rangeInfo");
        (, uint[] memory balances) = nftToken.totalBalance(msg.sender, nftIDs[_rid][_loop]);
        require(balances[_rangeIndex] > _num, "illegal balance");
        uint[] memory ids = new uint[](1);
        ids[0] = nftIDs[_rid][_loop][_rangeIndex];
        uint[] memory nums = new uint[](1);
        nums[0] = _num;
        nftToken.burnBatch(msg.sender, ids, nums);
    }

    function claim(uint256 _rid, uint256 _loop, address _to) external {
        require(_rid < roomInfo.length, "illegal rid"); 
        RoomInfo storage room = roomInfo[_rid];
        require(_loop < room.currentLoop || room.openNum == room.totalNum, "loop not finish");
        require(winers[_rid][_loop][_to] == true, "not the winner");
        uint reward = roomReward[_rid][_loop].div(winerNum[_rid][_loop]);

        claimedReward[_rid][_loop] = claimedReward[_rid][_loop].add(reward);
        delete winers[_rid][_loop][_to];
        uint[] memory balances = new uint256[](rangeInfo[_rid].length);
        for (uint i = 0; i < balances.length; i ++) {
            balances[i] = 1;
        }
        nftToken.burnBatch(_to, nftIDs[_rid][_loop], balances);

        SafeERC20.safeTransfer(room.token, _to, reward);
        emit Claim(_rid, _loop, _to, reward);
    }

    function ownerClaim(uint _rid, uint256 _loop) external onlyOwner {
        require(_rid < roomInfo.length, "illegal rid"); 
        RoomInfo storage room = roomInfo[_rid];
        require(room.openNum == room.totalNum, "loop not finish");
        require(_loop < room.currentLoop || room.openNum == room.totalNum, "loop not finish");
        require(winerNum[_rid][_loop] == 0 && roomReward[_rid][_loop] > 0, "already have winner");
        uint amount = roomReward[_rid][_loop];
        delete winerNum[_rid][_loop];
        SafeERC20.safeTransfer(room.token, receiver, amount); 
    }

    function userRecord(uint _rid, address user) external view returns (bool[] memory){
        RoomInfo storage room = roomInfo[_rid];
        bool[] memory res = new bool[](room.totalLoop);
        for (uint i = 1; i <= room.totalLoop; i ++) {
            res[i - 1] = winers[_rid][i][user];
        }
        return res;
    }
}
