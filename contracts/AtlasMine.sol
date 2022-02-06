// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import '@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol';

import './interfaces/IMasterOfCoin.sol';
import './interfaces/ILegionMetadataStore.sol';

contract AtlasMine is Initializable, AccessControlEnumerableUpgradeable, ERC1155HolderUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeCastUpgradeable for uint256;
    using SafeCastUpgradeable for int256;

    enum Lock { twoWeeks, oneMonth, threeMonths, sixMonths, twelveMonths }

    struct UserInfo {
        uint256 originalDepositAmount;
        uint256 depositAmount;
        uint256 lpAmount;
        //-- it is enough to use uint32 and move after `rewardDebt`, we can save gas that way
        uint256 lockedUntil;
        //-- it is enough to use uint32 and move after `rewardDebt`, we can save gas that way
        uint256 vestingLastUpdate;
        int256 rewardDebt;
        Lock lock;
    }

    bytes32 public constant ATLAS_MINE_ADMIN_ROLE = keccak256("ATLAS_MINE_ADMIN_ROLE");

    uint256 public constant DAY = 1 days;
    uint256 public constant ONE_WEEK = 7 days;
    uint256 public constant TWO_WEEKS = ONE_WEEK * 2;
    uint256 public constant ONE_MONTH = 30 days;
    uint256 public constant THREE_MONTHS = ONE_MONTH * 3;
    uint256 public constant SIX_MONTHS = ONE_MONTH * 6;
    uint256 public constant TWELVE_MONTHS = 365 days;
    uint256 public constant ONE = 1e18;

    // Magic token addr
    //-- type of magic could be simply IERC20, there is no upgradable functionality used in scope of Atlas
    IERC20Upgradeable public magic;
    IMasterOfCoin public masterOfCoin;

    bool public unlockAll;

    uint256 public totalRewardsEarned;
    uint256 public totalUndistributedRewards;
    uint256 public accMagicPerShare;
    uint256 public totalLpToken;
    uint256 public magicTotalDeposits;

    uint256 public utilizationOverride;
    EnumerableSetUpgradeable.AddressSet private excludedAddresses;

    address public legionMetadataStore;
    address public treasure;
    address public legion;

    // user => staked 1/1
    mapping(address => bool) public isLegion1_1Staked;
    //-- I did quick check and you can save 4K gas for every single read, if instead of [][] you will use mapping:
    //-- mapping (uint256 => mapping (uint256 => uint256))
    uint256[][] public legionBoostMatrix;

    /// @notice user => depositId => UserInfo
    mapping (address => mapping (uint256 => UserInfo)) public userInfo;
    /// @notice user => depositId[]
    mapping (address => EnumerableSetUpgradeable.UintSet) private allUserDepositIds;
    /// @notice user => deposit index
    mapping (address => uint256) public currentId;

    // user => tokenIds
    mapping (address => EnumerableSetUpgradeable.UintSet) private legionStaked;
    // user => tokenId => amount
    mapping (address => mapping(uint256 => uint256)) public treasureStaked;
    // user => total amount staked
    mapping (address => uint256) public treasureStakedAmount;
    // user => boost
    mapping (address => uint256) public boosts;

    //-- maybe indexed nft?
    event Staked(address nft, uint256 tokenId, uint256 amount, uint256 currentBoost);
    event Unstaked(address nft, uint256 tokenId, uint256 amount, uint256 currentBoost);

    event Deposit(address indexed user, uint256 indexed index, uint256 amount, Lock lock);
    event Withdraw(address indexed user, uint256 indexed index, uint256 amount);
    event UndistributedRewardsWithdraw(address indexed to, uint256 amount);
    event Harvest(address indexed user, uint256 indexed index, uint256 amount);
    event LogUpdateRewards(uint256 distributedRewards, uint256 undistributedRewards, uint256 lpSupply, uint256 accMagicPerShare);
    event UtilizationRate(uint256 util);

    modifier updateRewards() {
        uint256 lpSupply = totalLpToken;
        //-- this is uint, so it is enough to check !=
        if (lpSupply > 0) {
            (uint256 distributedRewards, uint256 undistributedRewards) = getRealMagicReward(masterOfCoin.requestRewards());
            //-- this calculations could be unchecked, SEE comment in summary
            totalRewardsEarned += distributedRewards;
            totalUndistributedRewards += undistributedRewards;
            accMagicPerShare += distributedRewards * ONE / lpSupply;
            emit LogUpdateRewards(distributedRewards, undistributedRewards, lpSupply, accMagicPerShare);
        }

        uint256 util = utilization();
        emit UtilizationRate(util);
        _;
    }

    function init(address _magic, address _masterOfCoin) external initializer {
        magic = IERC20Upgradeable(_magic);
        masterOfCoin = IMasterOfCoin(_masterOfCoin);

        _setRoleAdmin(ATLAS_MINE_ADMIN_ROLE, ATLAS_MINE_ADMIN_ROLE);
        _grantRole(ATLAS_MINE_ADMIN_ROLE, msg.sender);

        // array follows values from ILegionMetadataStore.LegionGeneration and ILegionMetadataStore.LegionRarity
        legionBoostMatrix = [
            // GENESIS
            // LEGENDARY,RARE,SPECIAL,UNCOMMON,COMMON,RECRUIT
            [uint256(600e16), uint256(200e16), uint256(75e16), uint256(100e16), uint256(50e16), uint256(0)],
            // AUXILIARY
            // LEGENDARY,RARE,SPECIAL,UNCOMMON,COMMON,RECRUIT
            [uint256(0), uint256(25e16), uint256(0), uint256(10e16), uint256(5e16), uint256(0)],
            // RECRUIT
            // LEGENDARY,RARE,SPECIAL,UNCOMMON,COMMON,RECRUIT
            [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)]
        ];

        __AccessControlEnumerable_init();
        __ERC1155Holder_init();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155ReceiverUpgradeable, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function getStakedLegions(address _user) external view virtual returns (uint256[] memory) {
        return legionStaked[_user].values();
    }

    function getUserBoost(address _user) external view virtual returns (uint256) {
        return boosts[_user];
    }

    function getLegionBoostMatrix() external view virtual returns (uint256[][] memory) {
        return legionBoostMatrix;
    }

    function getLegionBoost(uint256 _legionGeneration, uint256 _legionRarity) public view virtual returns (uint256) {
        //-- suggested mapping will simplify this condition to simple: legionBoostMatrix[_legionGeneration][_legionRarity]
        if (_legionGeneration < legionBoostMatrix.length && _legionRarity < legionBoostMatrix[_legionGeneration].length) {
            return legionBoostMatrix[_legionGeneration][_legionRarity];
        }
        return 0;
    }

    function utilization() public view virtual returns (uint256 util) {
        //-- it is enough to check !=
        if (utilizationOverride > 0) return utilizationOverride;

        uint256 circulatingSupply = magic.totalSupply();
        uint256 len = excludedAddresses.length();
        //-- this calculations could be unchecked, SEE comment in summary
        for (uint256 i = 0; i < len; i++) {
            circulatingSupply -= magic.balanceOf(excludedAddresses.at(i));
        }
        uint256 rewardsAmount = magic.balanceOf(address(this)) - magicTotalDeposits;
        circulatingSupply -= rewardsAmount;
        if (circulatingSupply != 0) {
            util = magicTotalDeposits * ONE / circulatingSupply;
        }
    }

    function getRealMagicReward(uint256 _magicReward)
        public
        view
        virtual
        returns (uint256 distributedRewards, uint256 undistributedRewards)
    {
        uint256 util = utilization();

        if (util < 3e17) {
            distributedRewards = 0;
        } else if (util < 4e17) { // >30%
            // 50%
            distributedRewards = _magicReward * 5 / 10;
        } else if (util < 5e17) { // >40%
            // 60%
            distributedRewards = _magicReward * 6 / 10;
        } else if (util < 6e17) { // >50%
            // 80%
            distributedRewards = _magicReward * 8 / 10;
        } else { // >60%
            // 100%
            distributedRewards = _magicReward;
        }

        undistributedRewards = _magicReward - distributedRewards;
    }

    function getAllUserDepositIds(address _user) public view virtual returns (uint256[] memory) {
        return allUserDepositIds[_user].values();
    }

    function getExcludedAddresses() public view virtual returns (address[] memory) {
        return excludedAddresses.values();
    }

    function getLockBoost(Lock _lock) public pure virtual returns (uint256 boost, uint256 timelock) {
        if (_lock == Lock.twoWeeks) {
            // 10%
            return (10e16, TWO_WEEKS);
        } else if (_lock == Lock.oneMonth) {
            // 25%
            return (25e16, ONE_MONTH);
        } else if (_lock == Lock.threeMonths) {
            // 80%
            return (80e16, THREE_MONTHS);
        } else if (_lock == Lock.sixMonths) {
            // 180%
            return (180e16, SIX_MONTHS);
        } else if (_lock == Lock.twelveMonths) {
            // 400%
            return (400e16, TWELVE_MONTHS);
        } else {
            revert("Invalid lock value");
        }
    }

    function getVestingTime(Lock _lock) public pure virtual returns (uint256 vestingTime) {
        if (_lock == Lock.twoWeeks) {
            vestingTime = 0;
        } else if (_lock == Lock.oneMonth) {
            vestingTime = 7 days;
        } else if (_lock == Lock.threeMonths) {
            vestingTime = 14 days;
        } else if (_lock == Lock.sixMonths) {
            vestingTime = 30 days;
        } else if (_lock == Lock.twelveMonths) {
            vestingTime = 45 days;
        }
    }

    function calcualteVestedPrincipal(address _user, uint256 _depositId) public view virtual returns (uint256 amount) {
        UserInfo storage user = userInfo[_user][_depositId];
        Lock _lock = user.lock;

        uint256 vestingEnd = user.lockedUntil + getVestingTime(_lock);
        uint256 vestingBegin = user.lockedUntil;

        if (block.timestamp >= vestingEnd || unlockAll) {
            amount = user.originalDepositAmount;
        } else if (block.timestamp > user.vestingLastUpdate) {
            amount = user.originalDepositAmount * (block.timestamp - user.vestingLastUpdate) / (vestingEnd - vestingBegin);
        }
    }

    function pendingRewardsPosition(address _user, uint256 _depositId) public view virtual returns (uint256 pending) {
        UserInfo storage user = userInfo[_user][_depositId];
        uint256 _accMagicPerShare = accMagicPerShare;
        //-- no need to cache it, we using it only once
        uint256 lpSupply = totalLpToken;

        (uint256 distributedRewards,) = getRealMagicReward(masterOfCoin.getPendingRewards(address(this)));
        _accMagicPerShare += distributedRewards * ONE / lpSupply;

        pending = ((user.lpAmount * _accMagicPerShare / ONE).toInt256() - user.rewardDebt).toUint256();
    }

    function pendingRewardsAll(address _user) external view virtual returns (uint256 pending) {
        uint256 len = allUserDepositIds[_user].length();
        for (uint256 i = 0; i < len; i++) {
            uint256 depositId = allUserDepositIds[_user].at(i);
            pending += pendingRewardsPosition(_user, depositId);
        }
    }

    function deposit(uint256 _amount, Lock _lock) public virtual updateRewards {
        (UserInfo storage user, uint256 depositId) = _addDeposit(msg.sender);
        (uint256 lockBoost, uint256 timelock) = getLockBoost(_lock);
        uint256 nftBoost = boosts[msg.sender];
        uint256 lpAmount = _amount + _amount * (lockBoost + nftBoost) / ONE;
        magicTotalDeposits += _amount;
        totalLpToken += lpAmount;

        user.originalDepositAmount = _amount;
        user.depositAmount = _amount;
        user.lpAmount = lpAmount;
        //-- unnecessary reading from storage user.lockedUntil, do:
        //-- lockedUntilCache = block.timestamp + timelock
        //-- then reuse lockedUntilCache in next 2 lines
        user.lockedUntil = block.timestamp + timelock;
        user.vestingLastUpdate = user.lockedUntil;
        user.rewardDebt = (lpAmount * accMagicPerShare / ONE).toInt256();
        user.lock = _lock;

        //-- no need for safe transfer if you using trusted tokens
        //-- based on a code I assume magic token will be trusted and you sure, there is no funky business there
        magic.safeTransferFrom(msg.sender, address(this), _amount);

        emit Deposit(msg.sender, depositId, _amount, _lock);
    }

    function withdrawPosition(uint256 _depositId, uint256 _amount) public virtual updateRewards returns (bool) {
        UserInfo storage user = userInfo[msg.sender][_depositId];
        uint256 depositAmount = user.depositAmount;
        if (depositAmount == 0) return false;

        if (_amount > depositAmount) {
            _amount = depositAmount;
        }
        // anyone can withdraw if kill swith was used
        if (!unlockAll) {
            require(block.timestamp >= user.lockedUntil, "Position is still locked");
            uint256 vestedAmount = _vestedPrincipal(msg.sender, _depositId);
            //-- shouldn't we check that regardless of kill switch?
            //-- it might be user friendly feature, so we do not throw when somebody miscalculated amount
            if (_amount > vestedAmount) {
                _amount = vestedAmount;
            }
        }

        // Effects
        uint256 ratio = _amount * ONE / depositAmount;
        uint256 lpAmount = user.lpAmount * ratio / ONE;

        totalLpToken -= lpAmount;
        magicTotalDeposits -= _amount;

        user.depositAmount -= _amount;
        user.lpAmount -= lpAmount;
        user.rewardDebt -= (lpAmount * accMagicPerShare / ONE).toInt256();

        // Interactions
        //-- no need for safe transfer if you using trusted tokens
        magic.safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _depositId, _amount);

        return true;
    }

    function withdrawAll() public virtual {
        uint256[] memory depositIds = allUserDepositIds[msg.sender].values();
        for (uint256 i = 0; i < depositIds.length; i++) {
            withdrawPosition(depositIds[i], type(uint256).max);
        }
    }

    function harvestPosition(uint256 _depositId) public virtual updateRewards {
        UserInfo storage user = userInfo[msg.sender][_depositId];

        int256 accumulatedMagic = (user.lpAmount * accMagicPerShare / ONE).toInt256();
        //-- I might not understand the logic completely yet, so question:
        //-- what sign is used to represent "real" debt (user.rewardDebt)? negative or positive?
        //-- if user.rewardDebt == -1 that means user has debt or surplus?
        //-- if real debt is positive value, then all good, otherwise you should sum up values, not subtract
        uint256 _pendingMagic = (accumulatedMagic - user.rewardDebt).toUint256();

        // Effects
        user.rewardDebt = accumulatedMagic;

        if (user.depositAmount == 0 && user.lpAmount == 0) {
            _removeDeposit(msg.sender, _depositId);
        }

        // Interactions
        if (_pendingMagic != 0) {
            //-- no need for safe transfer if you using trusted tokens
            magic.safeTransfer(msg.sender, _pendingMagic);
        }

        emit Harvest(msg.sender, _depositId, _pendingMagic);

        //-- if we update magic token, without sending new tokens to this contract, this will always fail
        require(magic.balanceOf(address(this)) >= magicTotalDeposits, "Run on banks");
    }

    function harvestAll() public virtual {
        uint256[] memory depositIds = allUserDepositIds[msg.sender].values();
        for (uint256 i = 0; i < depositIds.length; i++) {
            harvestPosition(depositIds[i]);
        }
    }

    function withdrawAndHarvestPosition(uint256 _depositId, uint256 _amount) public virtual {
        withdrawPosition(_depositId, _amount);
        harvestPosition(_depositId);
    }

    function withdrawAndHarvestAll() public virtual {
        uint256[] memory depositIds = allUserDepositIds[msg.sender].values();
        for (uint256 i = 0; i < depositIds.length; i++) {
            withdrawAndHarvestPosition(depositIds[i], type(uint256).max);
        }
    }

    function stakeTreasure(uint256 _tokenId, uint256 _amount) external virtual updateRewards {
        require(treasure != address(0), "Cannot stake Treasure");
        require(_amount > 0, "Amount is 0");

        treasureStaked[msg.sender][_tokenId] += _amount;
        treasureStakedAmount[msg.sender] += _amount;

        //-- multiple storage read, cache this `treasureStakedAmount[msg.sender] + _amount` and reuse it
        require(treasureStakedAmount[msg.sender] <= 20, "Max 20 treasures per wallet");

        uint256 boost = getNftBoost(treasure, _tokenId, _amount);
        //-- let's cache `boosts[msg.sender] + boost` and reuse it on emit, no need to read from storage multiple times
        boosts[msg.sender] += boost;

        _recalculateLpAmount(msg.sender);

        //-- is is enough to use IERC1155, we not using any of Upgradeable features here,
        //-- no need to scare people without reason :)
        IERC1155Upgradeable(treasure).safeTransferFrom(msg.sender, address(this), _tokenId, _amount, bytes(""));

        emit Staked(treasure, _tokenId, _amount, boosts[msg.sender]);
    }

    function unstakeTreasure(uint256 _tokenId, uint256 _amount) external virtual updateRewards {
        require(treasure != address(0), "Cannot stake Treasure");
        require(_amount > 0, "Amount is 0");
        require(treasureStaked[msg.sender][_tokenId] >= _amount, "Withdraw amount too big");

        treasureStaked[msg.sender][_tokenId] -= _amount;
        treasureStakedAmount[msg.sender] -= _amount;

        uint256 boost = getNftBoost(treasure, _tokenId, _amount);
        //-- let's cache `boosts[msg.sender] - boost` and reuse it on emit, no need to read from storage multiple times
        boosts[msg.sender] -= boost;

        _recalculateLpAmount(msg.sender);

        //-- is is enough to use IERC1155
        IERC1155Upgradeable(treasure).safeTransferFrom(address(this), msg.sender, _tokenId, _amount, bytes(""));

        emit Unstaked(treasure, _tokenId, _amount, boosts[msg.sender]);
    }

    function stakeLegion(uint256 _tokenId) external virtual updateRewards {
        require(legion != address(0), "Cannot stake Legion");
        require(legionStaked[msg.sender].add(_tokenId), "NFT already staked");
        require(legionStaked[msg.sender].length() <= 3, "Max 3 legions per wallet");

        if (isLegion1_1(_tokenId)) {
            require(!isLegion1_1Staked[msg.sender], "Max 1 1/1 legion per wallet");
            isLegion1_1Staked[msg.sender] = true;
        }

        uint256 boost = getNftBoost(legion, _tokenId, 1);
        //-- let's cache `boosts[msg.sender] + boost` and reuse it
        boosts[msg.sender] += boost;

        _recalculateLpAmount(msg.sender);

        //-- is is enough to use IERC721
        IERC721Upgradeable(legion).transferFrom(msg.sender, address(this), _tokenId);

        emit Staked(legion, _tokenId, 1, boosts[msg.sender]);
    }

    function unstakeLegion(uint256 _tokenId) external virtual updateRewards {
        require(legionStaked[msg.sender].remove(_tokenId), "NFT is not staked");

        if (isLegion1_1(_tokenId)) {
            isLegion1_1Staked[msg.sender] = false;
        }

        uint256 boost = getNftBoost(legion, _tokenId, 1);
        //-- let's cache `boosts[msg.sender] - boost` and reuse it
        boosts[msg.sender] -= boost;

        _recalculateLpAmount(msg.sender);

        //-- is is enough to use IERC721
        IERC721Upgradeable(legion).transferFrom(address(this), msg.sender, _tokenId);

        emit Unstaked(legion, _tokenId, 1, boosts[msg.sender]);

        //-- looks like there are few methods that are working based on same pattern:
        //        uint256 boost = getNftBoost(legion, _tokenId, 1/amount);
        //        boosts[msg.sender] +/-= boost;
        //        _recalculateLpAmount(msg.sender);
        //        IERC721Upgradeable(legion).transferFrom(address(this), msg.sender, _tokenId);
        //--
        //-- this could be easily wrapped with one method: less code is better ;) and easier to test
    }

    function isLegion1_1(uint256 _tokenId) public view virtual returns (bool) {
        //-- this try-catch does not bring any value, you not doing any custom actions on errors
        //-- same functionality could be done using simple .call, less code is better ;)

        try ILegionMetadataStore(legionMetadataStore).metadataForLegion(_tokenId) returns (ILegionMetadataStore.LegionMetadata memory metadata) {
            return metadata.legionGeneration == ILegionMetadataStore.LegionGeneration.GENESIS &&
                metadata.legionRarity == ILegionMetadataStore.LegionRarity.LEGENDARY;
        } catch Error(string memory /*reason*/) {
            return false;
        } catch Panic(uint256) {
            return false;
        } catch (bytes memory /*lowLevelData*/) {
            return false;
        }
    }

    function getNftBoost(address _nft, uint256 _tokenId, uint256 _amount) public view virtual returns (uint256) {
        if (_nft == treasure) {
            return getTreasureBoost(_tokenId, _amount);
        } else if (_nft == legion) {
            //-- this try-catch does not bring any value, you not doing any custom actions on errors
            //-- same functionality could be done using simple .call, less code is better ;)
            try ILegionMetadataStore(legionMetadataStore).metadataForLegion(_tokenId) returns (ILegionMetadataStore.LegionMetadata memory metadata) {
                return getLegionBoost(uint256(metadata.legionGeneration), uint256(metadata.legionRarity));
            } catch Error(string memory /*reason*/) {
                return 0;
            } catch Panic(uint256) {
                return 0;
            } catch (bytes memory /*lowLevelData*/) {
                return 0;
            }
        }

        return 0;
    }

    //-- we can avoid multiple storage access to boosts[_user], if we add additional param to this method eg:
    //-- _recalculateLpAmount(address _user, uint256 _nftBoost)
    function _recalculateLpAmount(address _user) internal virtual {
        uint256 nftBoost = boosts[_user];

        uint256[] memory depositIds = allUserDepositIds[_user].values();
        //-- I would check if caching `depositIds.length` will save gas here, `depositIds` is already memory, but maybe
        //-- but there is bigger issue here, there is a risk that we can run out of gas when too many deposits
        //-- you should calculate what is the max number of deposits contract can handle in scope of methods where
        //-- `_recalculateLpAmount` is used and then: either limit number of deposits OR implement some batch mechanism,
        //-- however batch mechanism might not be easy or even possible without pausing contract
        for (uint256 i = 0; i < depositIds.length; i++) {
            uint256 depositId = depositIds[i];
            UserInfo storage user = userInfo[_user][depositId];

            (uint256 lockBoost,) = getLockBoost(user.lock);
            uint256 _amount = user.depositAmount;
            uint256 newlLpAmount = _amount + _amount * (lockBoost + nftBoost) / ONE;
            uint256 oldLpAmount = user.lpAmount;

            if (newlLpAmount > oldLpAmount) {
                uint256 lpDiff = newlLpAmount - oldLpAmount;
                user.rewardDebt += (lpDiff * accMagicPerShare / ONE).toInt256();
                totalLpToken += lpDiff;
                user.lpAmount += lpDiff;
            } else if (newlLpAmount < oldLpAmount) {
                uint256 lpDiff = oldLpAmount - newlLpAmount;
                user.rewardDebt -= (lpDiff * accMagicPerShare / ONE).toInt256();
                totalLpToken -= lpDiff;
                user.lpAmount -= lpDiff;
            }
        }
    }

    function addExcludedAddress(address _exclude) external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) updateRewards {
        require(excludedAddresses.add(_exclude), "Address already excluded");
    }

    function removeExcludedAddress(address _excluded) external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) updateRewards {
        require(excludedAddresses.remove(_excluded), "Address is not excluded");
    }

    function setUtilizationOverride(uint256 _utilizationOverride) external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) updateRewards {
        utilizationOverride = _utilizationOverride;
    }

    function setMagicToken(address _magic) external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) {
        magic = IERC20Upgradeable(_magic);
        //-- it would be safer if you add this requirement after update:
        //--         require(magic.balanceOf(address(this)) >= magicTotalDeposits, "Run on banks");
        //-- otherwise some of the features will always fail, until contract will have enough new magic tokens
        //-- maybe at least some event, to notify about that important update?
    }

    function setTreasure(address _treasure) external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) {
        //-- this updates of addresses can do so many harm eg. I do not see any protection against even simple case:
        //-- user stake token from treasureA, and after update how we assure Atlas has representation of treasureB
        //-- to withdraw it bac kto user?
        //-- I can only assume, that all this issues must be resolved outside of the scope of Atlas
        //-- same for other addresses
        treasure = _treasure;
    }

    function setLegion(address _legion) external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) {
        legion = _legion;
    }

    function setLegionMetadataStore(address _legionMetadataStore) external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) {
        legionMetadataStore = _legionMetadataStore;
    }

    function setLegionBoostMatrix(uint256[][] memory _legionBoostMatrix) external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) {
        legionBoostMatrix = _legionBoostMatrix;
    }

    /// @notice EMERGENCY ONLY
    function toggleUnlockAll() external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) updateRewards {
        unlockAll = unlockAll ? false : true;
    }

    function withdrawUndistributedRewards(address _to) external virtual onlyRole(ATLAS_MINE_ADMIN_ROLE) updateRewards {
        uint256 _totalUndistributedRewards = totalUndistributedRewards;
        totalUndistributedRewards = 0;

        //-- no need for safe transfer
        magic.safeTransfer(_to, _totalUndistributedRewards);
        emit UndistributedRewardsWithdraw(_to, _totalUndistributedRewards);
    }

    function getTreasureBoost(uint256 _tokenId, uint256 _amount) public pure virtual returns (uint256 boost) {
        if (_tokenId == 39) { // Ancient Relic 8%
            boost = 75e15;
        } else if (_tokenId == 46) { // Bag of Rare Mushrooms 6.2%
            boost = 62e15;
        } else if (_tokenId == 47) { // Bait for Monsters 7.3%
            boost = 73e15;
        } else if (_tokenId == 48) { // Beetle-wing 0.8%
            boost = 8e15;
        } else if (_tokenId == 49) { // Blue Rupee 1.5%
            boost = 15e15;
        } else if (_tokenId == 51) { // Bottomless Elixir 7.6%
            boost = 76e15;
        } else if (_tokenId == 52) { // Cap of Invisibility 7.6%
            boost = 76e15;
        } else if (_tokenId == 53) { // Carriage 6.1%
            boost = 61e15;
        } else if (_tokenId == 54) { // Castle 7.3%
            boost = 71e15;
        } else if (_tokenId == 68) { // Common Bead 5.6%
            boost = 56e15;
        } else if (_tokenId == 69) { // Common Feather 3.4%
            boost = 34e15;
        } else if (_tokenId == 71) { // Common Relic 2.2%
            boost = 22e15;
        } else if (_tokenId == 72) { // Cow 5.8%
            boost = 58e15;
        } else if (_tokenId == 73) { // Diamond 0.8%
            boost = 8e15;
        } else if (_tokenId == 74) { // Divine Hourglass 6.3%
            boost = 63e15;
        } else if (_tokenId == 75) { // Divine Mask 5.7%
            boost = 57e15;
        } else if (_tokenId == 76) { // Donkey 1.2%
            boost = 12e15;
        } else if (_tokenId == 77) { // Dragon Tail 0.8%
            boost = 8e15;
        } else if (_tokenId == 79) { // Emerald 0.8%
            boost = 8e15;
        } else if (_tokenId == 82) { // Favor from the Gods 5.6%
            boost = 56e15;
        } else if (_tokenId == 91) { // Framed Butterfly 5.8%
            boost = 58e15;
        } else if (_tokenId == 92) { // Gold Coin 0.8%
            boost = 8e15;
        } else if (_tokenId == 93) { // Grain 3.2%
            boost = 32e15;
        } else if (_tokenId == 94) { // Green Rupee 3.3%
            boost = 33e15;
        } else if (_tokenId == 95) { // Grin 15.7%
            boost = 157e15;
        } else if (_tokenId == 96) { // Half-Penny 0.8%
            boost = 8e15;
        } else if (_tokenId == 97) { // Honeycomb 15.8%
            boost = 158e15;
        } else if (_tokenId == 98) { // Immovable Stone 7.2%
            boost = 72e15;
        } else if (_tokenId == 99) { // Ivory Breastpin 6.4%
            boost = 64e15;
        } else if (_tokenId == 100) { // Jar of Fairies 5.3%
            boost = 53e15;
        } else if (_tokenId == 103) { // Lumber 3%
            boost = 30e15;
        } else if (_tokenId == 104) { // Military Stipend 6.2%
            boost = 62e15;
        } else if (_tokenId == 105) { // Mollusk Shell 6.7%
            boost = 67e15;
        } else if (_tokenId == 114) { // Ox 1.6%
            boost = 16e15;
        } else if (_tokenId == 115) { // Pearl 0.8%
            boost = 8e15;
        } else if (_tokenId == 116) { // Pot of Gold 5.8%
            boost = 58e15;
        } else if (_tokenId == 117) { // Quarter-Penny 0.8%
            boost = 8e15;
        } else if (_tokenId == 132) { // Red Feather 6.4%
            boost = 64e15;
        } else if (_tokenId == 133) { // Red Rupee 0.8%
            boost = 8e15;
        } else if (_tokenId == 141) { // Score of Ivory 6%
            boost = 60e15;
        } else if (_tokenId == 151) { // Silver Coin 0.8%
            boost = 8e15;
        } else if (_tokenId == 152) { // Small Bird 6%
            boost = 60e15;
        } else if (_tokenId == 153) { // Snow White Feather 6.4%
            boost = 64e15;
        } else if (_tokenId == 161) { // Thread of Divine Silk 7.3%
            boost = 73e15;
        } else if (_tokenId == 162) { // Unbreakable Pocketwatch 5.9%
            boost = 59e15;
        } else if (_tokenId == 164) { // Witches Broom 5.1%
            boost = 51e15;
        }

        boost = boost * _amount;
    }

    function _vestedPrincipal(address _user, uint256 _depositId) internal virtual returns (uint256 amount) {
        amount = calcualteVestedPrincipal(_user, _depositId);
        UserInfo storage user = userInfo[_user][_depositId];
        user.vestingLastUpdate = block.timestamp;
    }

    function _addDeposit(address _user) internal virtual returns (UserInfo storage user, uint256 newDepositId) {
        // start depositId from 1
        newDepositId = ++currentId[_user];
        allUserDepositIds[_user].add(newDepositId);
        user = userInfo[_user][newDepositId];
    }

    function _removeDeposit(address _user, uint256 _depositId) internal virtual {
        require(allUserDepositIds[_user].remove(_depositId), 'depositId !exists');
    }
}
