// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.7;
//
// import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
// import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
// import '@openzeppelin/contracts/access/Ownable.sol';
// import '@openzeppelin/contracts/utils/math/SafeCast.sol';
//
// contract AtlasMineAlternative is Ownable {
//     using SafeERC20 for ERC20;
//     using SafeCast for uint256;
//     using SafeCast for int256;
//
//     enum Lock { twoWeeks, oneMonth, threeMonths, sixMonths, twelveMonths }
//
//     uint256 public constant ONE = 1e18;
//     uint256 public constant DAY = 1 days;
//     uint256 public constant ONE_WEEK = 7 days;
//     uint256 public constant TWO_WEEKS = ONE_WEEK * 2;
//     uint256 public constant ONE_MONTH = 30 days;
//     uint256 public constant THREE_MONTHS = ONE_MONTH * 3;
//     uint256 public constant SIX_MONTHS = ONE_MONTH * 6;
//     uint256 public constant TWELVE_MONTHS = 365 days;
//     uint256 public constant ONE = 1e18;
//
//     // Magic token addr
//     ERC20 public immutable magic;
//     address public immutable treasuryStake;
//
//     bool public unlockAll;
//     uint256 public endTimestamp;
//     uint256 public startTimestamp;
//
//     uint256 public maxMagicPerSecond;
//     uint256 public magicPerSecond;
//     uint256 public totalRewardsEarned;
//     uint256 public totalUndistributedRewards;
//     uint256 public accMagicPerShare;
//     uint256 public totalLpToken;
//     uint256 public magicTotalDeposits;
//     uint256 public lastRewardTimestamp;
//
//     address[] public excludedAddresses;
//
//     struct UserInfo {
//         uint256 depositAmount;
//         uint256 lpAmount;
//         uint256 lockedUntil;
//         int256 rewardDebt;
//         Lock lock;
//     }
//
//     /// @notice user => depositId => UserInfo
//     mapping (address => mapping (uint256 => UserInfo)) public userInfo;
//     /// @notice user => depositId[]
//     mapping (address => uint256[]) public allUserDepositIds;
//     /// @notice user => depositId => index in allUserDepositIds
//     mapping (address => mapping(uint256 => uint256)) public depositIdIndex;
//     /// @notice user => deposit index array
//     mapping (address => uint256) public currentId;
//
//     event Deposit(address indexed user, uint256 indexed index, uint256 amount);
//     event Withdraw(address indexed user, uint256 indexed index, uint256 amount);
//     event EmergencyWithdraw(address indexed to, uint256 amount);
//     event Harvest(address indexed user, uint256 indexed index, uint256 amount);
//     event LogUpdateRewards(uint256 indexed lastRewardTimestamp, uint256 lpSupply, uint256 accMagicPerShare);
//
//     modifier refreshMagicRate() {
//         _;
//         uint256 util = utilization();
//         if (util < 2e17) {
//             magicPerSecond = 0;
//         } else if (util < 3e17) { // >20%
//             // 50%
//             magicPerSecond = maxMagicPerSecond * 5 / 10;
//         } else if (util < 4e17) { // >30%
//             // 60%
//             magicPerSecond = maxMagicPerSecond * 6 / 10;
//         } else if (util < 5e17) { // >40%
//             // 80%
//             magicPerSecond = maxMagicPerSecond * 8 / 10;
//         } else if (util < 6e17) { // >50%
//             // 90%
//             magicPerSecond = maxMagicPerSecond * 9 / 10;
//         } else { // >60%
//             // 100%
//             magicPerSecond = maxMagicPerSecond;
//         }
//     }
//
//     modifier updateRewards() {
//         if (
//             block.timestamp > lastRewardTimestamp &&
//             lastRewardTimestamp < endTimestamp &&
//             endTimestamp != 0 &&
//             block.timestamp > startTimestamp
//         ) {
//             uint256 lpSupply = totalLpToken;
//             if (lpSupply > 0) {
//                 uint256 timeDelta;
//                 if (block.timestamp > endTimestamp) {
//                     timeDelta = endTimestamp - lastRewardTimestamp;
//                     lastRewardTimestamp = endTimestamp;
//                 } else {
//                     timeDelta = block.timestamp - lastRewardTimestamp;
//                     lastRewardTimestamp = block.timestamp;
//                 }
//                 (uint256 distributedRewards, uint256 undistributedRewards) = getRealMagicReward(timeDelta);
//                 totalRewardsEarned += distributedRewards;
//                 totalUndistributedRewards += undistributedRewards;
//                 accMagicPerShare += distributedRewards * ONE / lpSupply;
//             }
//             emit LogUpdateRewards(lastRewardTimestamp, lpSupply, accMagicPerShare);
//         }
//         _;
//     }
//
//     constructor(address _magic, address _masterOfCoin) {
//         magic = ERC20(_magic);
//         masterOfCoin = IMasterOfCoin(_masterOfCoin);
//
//         maxMagicPerSecond = masterOfCoin.getRatePerSecond(address(this));
//         IMasterOfCoin.CoinStream memory config = masterOfCoin.getStreamConfig(address(this));
//         startTimestamp = config.startTimestamp;
//         endTimestamp = config.endTimestamp;
//         lastRewardTimestamp = config.startTimestamp;
//     }
//
//     function utilization() public view returns (uint256 util) {
//         uint256 circulatingSupply = magic.totalSupply();
//         uint256 len = excludedAddresses.length;
//         for (uint256 i = 0; i < len; i++) {
//             circulatingSupply -= magic.balanceOf(excludedAddresses[i]);
//         }
//         uint256 rewardsAmount = magic.balanceOf(address(this)) - magicTotalDeposits;
//         circulatingSupply -= rewardsAmount;
//         if (circulatingSupply != 0) {
//             util = magicTotalDeposits * ONE / circulatingSupply;
//         }
//     }
//
//     function getRealMagicReward(uint256 _timeDelta)
//         public
//         view
//         returns (uint256 distributedRewards, uint256 undistributedRewards)
//     {
//         distributedRewards = _timeDelta * magicPerSecond;
//         undistributedRewards = _timeDelta * (maxMagicPerSecond - magicPerSecond);
//     }
//
//     function getAllUserDepositIds(address _user) public view returns (uint256[] memory) {
//         return allUserDepositIds[_user];
//     }
//
//     function getExcludedAddresses() public view returns (address[] memory) {
//         return excludedAddresses;
//     }
//
//     function getBoost(Lock _lock) public pure returns (uint256 boost, uint256 timelock) {
//         if (_lock == Lock.twoWeeks) {
//             // 10%
//             return (1e17, TWO_WEEKS);
//         } else if (_lock == Lock.oneMonth) {
//             // 25%
//             return (25e16, ONE_MONTH);
//         } else if (_lock == Lock.threeMonths) {
//             // 80%
//             return (8e17, THREE_MONTHS);
//         } else if (_lock == Lock.sixMonths) {
//             // 180%
//             return (18e17, SIX_MONTHS);
//         } else if (_lock == Lock.twelveMonths) {
//             // 400%
//             return (8e17, TWELVE_MONTHS);
//         } else {
//             revert("Invalid lock value");
//         }
//     }
//
//     function pendingRewardsPosition(address _user, uint256 _depositId) public view returns (uint256 pending) {
//         UserInfo storage user = userInfo[_user][_depositId];
//         uint256 _accMagicPerShare = accMagicPerShare;
//         uint256 lpSupply = totalLpToken;
//         if (block.timestamp > lastRewardTimestamp && magicPerSecond != 0) {
//             uint256 timeDelta;
//             if (block.timestamp > endTimestamp) {
//                 timeDelta = endTimestamp - lastRewardTimestamp;
//             } else {
//                 timeDelta = block.timestamp - lastRewardTimestamp;
//             }
//             uint256 magicReward = timeDelta * magicPerSecond;
//             // send 10% to treasury
//             uint256 treasuryReward = magicReward / 10;
//             magicReward -= treasuryReward;
//
//             _accMagicPerShare += magicReward * ONE / lpSupply;
//         }
//
//         pending = ((user.lpAmount * _accMagicPerShare / ONE).toInt256() - user.rewardDebt).toUint256();
//     }
//
//     function pendingRewardsAll(address _user) external view returns (uint256 pending) {
//         uint256 len = allUserDepositIds[_user].length;
//         for (uint256 i = 0; i < len; ++i) {
//             uint256 depositId = allUserDepositIds[_user][i];
//             pending += pendingRewardsPosition(_user, depositId);
//         }
//     }
//
//     function deposit(uint256 _amount, Lock _lock) public refreshMagicRate updateRewards {
//         require(isInitialized(), "Not initialized");
//
//         (UserInfo storage user, uint256 depositId) = _addDeposit(msg.sender);
//         (uint256 boost, uint256 timelock) = getBoost(_lock);
//         uint256 lpAmount = _amount + _amount * boost / ONE;
//         magicTotalDeposits += _amount;
//         totalLpToken += lpAmount;
//
//         user.depositAmount = _amount;
//         user.lpAmount = lpAmount;
//         user.lockedUntil = block.timestamp + timelock;
//         user.rewardDebt = (lpAmount * accMagicPerShare / ONE).toInt256();
//         user.lock = _lock;
//
//         magic.safeTransferFrom(msg.sender, address(this), _amount);
//
//         emit Deposit(msg.sender, depositId, _amount);
//     }
//
//     function withdrawPosition(uint256 _depositId, uint256 _amount) public refreshMagicRate updateRewards {
//         UserInfo storage user = userInfo[msg.sender][_depositId];
//         uint256 depositAmount = user.depositAmount;
//         require(depositAmount > 0, "Position does not exists");
//
//         if (_amount > depositAmount) {
//             _amount = depositAmount;
//         }
//         // anyone can withdraw when mine ends or kill swith was used
//         if (block.timestamp < endTimestamp && !unlockAll) {
//             require(block.timestamp >= user.lockedUntil, "Position is still locked");
//         }
//
//         // Effects
//         uint256 ratio = _amount * ONE / depositAmount;
//         uint256 lpAmount = user.lpAmount * ratio / ONE;
//
//         totalLpToken -= lpAmount;
//         magicTotalDeposits -= _amount;
//
//         user.depositAmount -= _amount;
//         user.lpAmount -= lpAmount;
//         user.rewardDebt -= (lpAmount * accMagicPerShare / ONE).toInt256();
//
//         // Interactions
//         magic.safeTransfer(msg.sender, _amount);
//
//         emit Withdraw(msg.sender, _depositId, _amount);
//     }
//
//     function withdrawAll() public {
//         uint256[] memory depositIds = allUserDepositIds[msg.sender];
//         uint256 len = depositIds.length;
//         for (uint256 i = 0; i < len; ++i) {
//             uint256 depositId = depositIds[i];
//             withdrawPosition(depositId, type(uint256).max);
//         }
//     }
//
//     function harvestPosition(uint256 _depositId) public refreshMagicRate updateRewards {
//         UserInfo storage user = userInfo[msg.sender][_depositId];
//
//         int256 accumulatedMagic = (user.lpAmount * accMagicPerShare / ONE).toInt256();
//         uint256 _pendingMagic = (accumulatedMagic - user.rewardDebt).toUint256();
//
//         // Effects
//         user.rewardDebt = accumulatedMagic;
//
//         if (user.depositAmount == 0 && user.lpAmount == 0) {
//             _removeDeposit(msg.sender, _depositId);
//         }
//
//         // Interactions
//         if (_pendingMagic != 0) {
//             magic.safeTransfer(msg.sender, _pendingMagic);
//         }
//
//         emit Harvest(msg.sender, _depositId, _pendingMagic);
//     }
//
//     function harvestAll() public {
//         uint256[] memory depositIds = allUserDepositIds[msg.sender];
//         uint256 len = depositIds.length;
//         for (uint256 i = 0; i < len; ++i) {
//             uint256 depositId = depositIds[i];
//             harvestPosition(depositId);
//         }
//     }
//
//     function withdrawAndHarvestPosition(uint256 _depositId, uint256 _amount) public {
//         withdrawPosition(_depositId, _amount);
//         harvestPosition(_depositId);
//     }
//
//     function withdrawAndHarvestAll() public {
//         uint256[] memory depositIds = allUserDepositIds[msg.sender];
//         uint256 len = depositIds.length;
//         for (uint256 i = 0; i < len; ++i) {
//             uint256 depositId = depositIds[i];
//             withdrawAndHarvestPosition(depositId, type(uint256).max);
//         }
//     }
//
//     function preRateUpdate() external {
//         masterOfCoin.requestRewards();
//     }
//
//     function postRateUpdate() external refreshMagicRate updateRewards {
//         maxMagicPerSecond = masterOfCoin.getRatePerSecond(address(this));
//         IMasterOfCoin.CoinStream memory config = masterOfCoin.getStreamConfig(address(this));
//         startTimestamp = config.startTimestamp;
//         endTimestamp = config.endTimestamp;
//     }
//
//     function addExcludedAddress(address exclude) external onlyOwner refreshMagicRate updateRewards {
//         uint256 len = excludedAddresses.length;
//         for (uint256 i = 0; i < len; ++i) {
//             require(excludedAddresses[i] != exclude, "Already excluded");
//         }
//         excludedAddresses.push(exclude);
//     }
//
//     function removeExcludedAddress(address include) external onlyOwner refreshMagicRate updateRewards {
//         uint256 index;
//         uint256 len = excludedAddresses.length;
//         require(len > 0, "no excluded addresses");
//         for (uint256 i = 0; i < len; ++i) {
//             if (excludedAddresses[i] == include) {
//                 index = i;
//                 break;
//             }
//         }
//         require(excludedAddresses[index] == include, "address not excluded");
//
//         uint256 lastIndex = len - 1;
//         if (index != lastIndex) {
//             excludedAddresses[index] = excludedAddresses[lastIndex];
//         }
//         excludedAddresses.pop();
//     }
//
//     /// @notice EMERGENCY ONLY
//     // TODO: how to calcualte undistributedRewards
//     function kill() external onlyOwner refreshMagicRate updateRewards {
//         require(!unlockAll, "Already dead");
//
//         int256 withdrawAmount =
//             (block.timestamp * maxMagicPerSecond).toInt256() // rewards originally sent
//             - (totalRewardsEarned).toInt256() // rewards distributed to users
//         if (withdrawAmount > 0) {
//             magic.safeTransfer(owner(), uint256(withdrawAmount));
//             emit EmergencyWithdraw(owner(), uint256(withdrawAmount));
//         }
//         maxMagicPerSecond = 0;
//         magicPerSecond = 0;
//         unlockAll = true;
//     }
//
//     function _addDeposit(address _user) internal returns (UserInfo storage user, uint256 newDepositId) {
//         // start depositId from 1
//         newDepositId = ++currentId[_user];
//         depositIdIndex[_user][newDepositId] = allUserDepositIds[_user].length;
//         allUserDepositIds[_user].push(newDepositId);
//         user = userInfo[_user][newDepositId];
//     }
//
//     function _removeDeposit(address _user, uint256 _depositId) internal {
//         uint256 depositIndex = depositIdIndex[_user][_depositId];
//
//         require(allUserDepositIds[_user][depositIndex] == _depositId, 'depositId !exists');
//
//         uint256 lastDepositIndex = allUserDepositIds[_user].length - 1;
//         if (depositIndex != lastDepositIndex) {
//             uint256 lastDepositId = allUserDepositIds[_user][lastDepositIndex];
//             allUserDepositIds[_user][depositIndex] = lastDepositId;
//             depositIdIndex[_user][lastDepositId] = depositIndex;
//         }
//         allUserDepositIds[_user].pop();
//         delete depositIdIndex[_user][_depositId];
//     }
// }
