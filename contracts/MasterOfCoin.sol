// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol';
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import './interfaces/IMasterOfCoin.sol';
import './interfaces/IStream.sol';

contract MasterOfCoin is IMasterOfCoin, Initializable, AccessControlEnumerableUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant MASTER_OF_COIN_ADMIN_ROLE = keccak256("MASTER_OF_COIN_ADMIN_ROLE");

    //-- based on a usage I think it is enough to use IERC20
    IERC20Upgradeable public magic;

    /// @notice stream address => CoinStream
    mapping (address => CoinStream) public streamConfig;

    /// @notice stream ID => stream address
    EnumerableSetUpgradeable.AddressSet private streams;

    /// @notice stream address => bool
    mapping (address => bool) public callbackRegistry;

    modifier streamExists(address _stream) {
        //-- you using solidity v8, so you can use Errors instead of require, to save gas
        require(streams.contains(_stream), "Stream does not exist");
        _;
    }

    modifier streamActive(address _stream) {
        //-- what about start date? is it active if not started yet?
        require(streamConfig[_stream].endTimestamp > block.timestamp, "Stream ended");
        _;
    }

    modifier callbackStream(address _stream) {
        if (callbackRegistry[_stream]) IStream(_stream).preRateUpdate();
        _;
        if (callbackRegistry[_stream]) IStream(_stream).postRateUpdate();
    }

    event StreamAdded(address indexed stream, uint256 amount, uint256 startTimestamp, uint256 endTimestamp);
    event StreamTimeUpdated(address indexed stream, uint256 startTimestamp, uint256 endTimestamp);

    event StreamGrant(address indexed stream, address from, uint256 amount);
    event StreamFunded(address indexed stream, uint256 amount);
    event StreamDefunded(address indexed stream, uint256 amount);
    event StreamRemoved(address indexed stream);

    event RewardsPaid(address indexed stream, uint256 rewardsPaid, uint256 rewardsPaidInTotal);
    event Withdraw(address to, uint256 amount);
    event CallbackSet(address stream, bool value);

    function init(address _magic) external initializer {
        magic = IERC20Upgradeable(_magic);

        _setRoleAdmin(MASTER_OF_COIN_ADMIN_ROLE, MASTER_OF_COIN_ADMIN_ROLE);
        _grantRole(MASTER_OF_COIN_ADMIN_ROLE, msg.sender);

        __AccessControlEnumerable_init();
    }

    function requestRewards() public virtual returns (uint256 rewardsPaid) {
        CoinStream storage stream = streamConfig[msg.sender];

        rewardsPaid = getPendingRewards(msg.sender);

        if (rewardsPaid == 0 || magic.balanceOf(address(this)) < rewardsPaid) {
            return 0;
        }

        //-- we can `unchecked` next line, you check impossible few lines below anyway
        stream.paid += rewardsPaid;
        stream.lastRewardTimestamp = block.timestamp;

        // this should never happen but better safe than sorry
        require(stream.paid <= stream.totalRewards, "Rewards overflow");

        //-- assuming this is  trusted token, no need to spend gas on safe transfer
        magic.safeTransfer(msg.sender, rewardsPaid);
        emit RewardsPaid(msg.sender, rewardsPaid, stream.paid);
    }

    function grantTokenToStream(address _stream, uint256 _amount)
        public
        virtual
        streamExists(_stream)
        streamActive(_stream)
    {
        //-- we doing external calls inside `_fundStream` but there is no reentrancy protection,
        //-- it will be much safer, to move this line at the end, after we emit event and get tokens
        _fundStream(_stream, _amount);

        //-- no need for safe transfer
        magic.safeTransferFrom(msg.sender, address(this), _amount);
        emit StreamGrant(_stream, msg.sender, _amount);
    }

    function getStreams() external view virtual returns (address[] memory) {
        return streams.values();
    }

    function getStreamConfig(address _stream) external view virtual returns (CoinStream memory) {
        return streamConfig[_stream];
    }

    function getGlobalRatePerSecond() external view virtual returns (uint256 globalRatePerSecond) {
        uint256 len = streams.length();
        for (uint256 i = 0; i < len; i++) {
            globalRatePerSecond += getRatePerSecond(streams.at(i));
        }
    }

    function getRatePerSecond(address _stream) public view virtual returns (uint256 ratePerSecond) {
        CoinStream storage stream = streamConfig[_stream];

        //-- shouldn't start date be inclusive?
        if (stream.startTimestamp < block.timestamp && block.timestamp < stream.endTimestamp) {
            ratePerSecond = stream.ratePerSecond;
        }
    }

    function getPendingRewards(address _stream) public view virtual returns (uint256 pendingRewards) {
        CoinStream storage stream = streamConfig[_stream];

        uint256 paid = stream.paid;
        uint256 totalRewards = stream.totalRewards;
        uint256 lastRewardTimestamp = stream.lastRewardTimestamp;

        if (block.timestamp >= stream.endTimestamp) {
            // stream ended
            pendingRewards = totalRewards - paid;

            //-- maybe it should be inclusive? >=
        } else if (block.timestamp > lastRewardTimestamp) {
            // stream active
            uint256 secondsFromLastPull = block.timestamp - lastRewardTimestamp;
            pendingRewards = secondsFromLastPull * stream.ratePerSecond;

            // in case of rounding error, make sure that paid + pending rewards is never more than totalRewards
            //-- there is no such a thing as rounding error in solidity, division is not rounded up
            //-- in case result would be 0.99999 (as floating number) -> it will be 0 in solidity
            //-- so called "rounding error" will be possible in case of human error,
            //-- when calculations are done in wrong order, but af fas I can tell, calculations looks ok,
            //-- so this check is not necessary imo
            if (paid + pendingRewards > totalRewards) {
                pendingRewards = totalRewards - paid;
            }
        }
    }

    function _fundStream(address _stream, uint256 _amount) internal virtual callbackStream(_stream) {
        CoinStream storage stream = streamConfig[_stream];

        //-- we can unchecked all 4 below lines, if token will not overflow, then nor do we
        uint256 secondsToEnd = stream.endTimestamp - stream.lastRewardTimestamp;
        uint256 rewardsLeft = secondsToEnd * stream.ratePerSecond;
        stream.ratePerSecond = (rewardsLeft + _amount) / secondsToEnd;
        stream.totalRewards += _amount;
    }

    // ADMIN

    /// @param _stream address of the contract that gets rewards
    /// @param _totalRewards amount of MAGIC that should be distributed in total
    /// @param _startTimestamp when MAGIC stream should start
    /// @param _endTimestamp when MAGIC stream should end
    /// @param _callback should callback be used (if you don't know, set false)
    function addStream(
        address _stream,
        uint256 _totalRewards,
        uint256 _startTimestamp,
        uint256 _endTimestamp,
        bool _callback
    ) external virtual onlyRole(MASTER_OF_COIN_ADMIN_ROLE) {
        require(_endTimestamp > _startTimestamp, "Rewards must last > 1 sec");
        require(!streams.contains(_stream), "Stream for address already exists");

        if (streams.add(_stream)) {
            streamConfig[_stream] = CoinStream({
                totalRewards: _totalRewards,
                startTimestamp: _startTimestamp,
                endTimestamp: _endTimestamp,
                lastRewardTimestamp: _startTimestamp,
                ratePerSecond: _totalRewards / (_endTimestamp - _startTimestamp),
                paid: 0
            });
            emit StreamAdded(_stream, _totalRewards, _startTimestamp, _endTimestamp);

            setCallback(_stream, _callback);
        }
    }

    function fundStream(address _stream, uint256 _amount)
        external
        virtual
        onlyRole(MASTER_OF_COIN_ADMIN_ROLE)
        streamExists(_stream)
        streamActive(_stream)
    {
        //-- I would first emit event, then call `_fundStream` because of external callbacks,
        //-- it is easier to trace what is going on that way
        _fundStream(_stream, _amount);
        emit StreamFunded(_stream, _amount);
    }

    function defundStream(address _stream, uint256 _amount)
        external
        virtual
        onlyRole(MASTER_OF_COIN_ADMIN_ROLE)
        streamExists(_stream)
        streamActive(_stream)
        callbackStream(_stream)
    {
        CoinStream storage stream = streamConfig[_stream];

        uint256 secondsToEnd = stream.endTimestamp - stream.lastRewardTimestamp;
        uint256 rewardsLeft = secondsToEnd * stream.ratePerSecond;

        require(_amount <= rewardsLeft, "Reduce amount too large, rewards already paid");

        stream.ratePerSecond = (rewardsLeft - _amount) / secondsToEnd;
        stream.totalRewards -= _amount;

        emit StreamDefunded(_stream, _amount);
    }

    function updateStreamTime(address _stream, uint256 _startTimestamp, uint256 _endTimestamp)
        external
        virtual
        onlyRole(MASTER_OF_COIN_ADMIN_ROLE)
        streamExists(_stream)
        callbackStream(_stream)
    {
        CoinStream storage stream = streamConfig[_stream];

        //-- check of != is enough
        if (_startTimestamp > 0) {
            require(_startTimestamp > block.timestamp, "startTimestamp cannot be in the past");

            stream.startTimestamp = _startTimestamp;
            stream.lastRewardTimestamp = _startTimestamp;
        }

        //-- check of != is enough
        if (_endTimestamp > 0) {
            require(_endTimestamp > _startTimestamp, "Rewards must last > 1 sec");
            require(_endTimestamp > block.timestamp, "Cannot end rewards in the past");

            stream.endTimestamp = _endTimestamp;
        }

        stream.ratePerSecond = (stream.totalRewards - stream.paid) / (stream.endTimestamp - stream.lastRewardTimestamp);

        emit StreamTimeUpdated(_stream, _startTimestamp, _endTimestamp);
    }

    function removeStream(address _stream)
        external
        virtual
        onlyRole(MASTER_OF_COIN_ADMIN_ROLE)
        streamExists(_stream)
        callbackStream(_stream)
    {
        if (streams.remove(_stream)) {
            delete streamConfig[_stream];
            emit StreamRemoved(_stream);
        }
    }

    function setCallback(address _stream, bool _value)
        public
        virtual
        onlyRole(MASTER_OF_COIN_ADMIN_ROLE)
        streamExists(_stream)
        //-- looks like redundant notification about rate change,
        //-- there is no rate change when we changing callback settings
        callbackStream(_stream)
    {
        callbackRegistry[_stream] = _value;
        emit CallbackSet(_stream, _value);
    }

    function withdrawMagic(address _to, uint256 _amount) external virtual onlyRole(MASTER_OF_COIN_ADMIN_ROLE) {
        //-- I do not see a reason to use safe transfer here, this is just one command, we can remove event and
        //-- rely on token transfer event, no dependency here, no need to protect anything
        magic.safeTransfer(_to, _amount);
        emit Withdraw(_to, _amount);
    }

    function setMagicToken(address _magic) external virtual onlyRole(MASTER_OF_COIN_ADMIN_ROLE) {
        //-- so, we can change reward token any time?
        //-- one second we claim for token A, another second we claim and we can get token B? that is real magic!
        //-- admin can basically switch tokens any time, use some dummy ERC20 and users which claims rewards will get
        //-- useless coins.
        //-- If this is requested feature, then we should at lest add event, so anyone can be warned, when this happen.
        magic = IERC20Upgradeable(_magic);
        //-- it would be safer, if you add requirement to check if contract has enough magic after setting up new token
    }
}
