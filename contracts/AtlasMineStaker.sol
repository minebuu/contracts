// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "treasure-staking/contracts/AtlasMine.sol";
import "./interfaces/IAtlasMineStaker.sol";

import "hardhat/console.sol";

// TODO: Re-do stake accounting to match atlas mine exactly
// TODO: Re-do treasure and legion approvals

/**
 * @title AtlasMineStaker
 * @author kvk0x
 *
 * Dragon of the Magic Dragon DAO - A Tempting Offer.
 *
 * Staking pool contract for the Bridgeworld Atlas Mine.
 * Wraps existing staking with a defined 'lock time' per contract.
 *
 * Better than solo staking since a designated 'hoard' can also
 * deposit Treasures and Legions for staking boosts. Anyone can
 * enjoy the power of the guild's hoard and maximize their
 * Atlas Mine yield.
 *
 * This contract assumes the canonical address of the MAGIC token
 * and is suitable for deployment on Arbitrum only.
 */
contract AtlasMineStaker is Ownable, IAtlasMineStaker {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ============================================ STATE ==============================================

    // ============= Global State ==============

    /// @notice MAGIC token
    address public immutable magic;
    /// @notice Holder of treasures and legions
    address private hoard;
    /// @notice The AtlasMine
    AtlasMine public immutable mine;
    /// @notice The defined lock cycle for the contract
    AtlasMine.Lock public immutable lock;

    // ============= Staking State ==============

    uint256 public constant ONE = 1e18;

    /// @notice An individual stake i.e. deposit
    struct Stake {
        uint256 amount;
        uint256 unlockAt;
        uint256 depositId;
    }

    /// @notice Whether new stakes will get staked on the contract as scheduled. For emergencies
    bool public schedulePaused;
    /// @notice Deposited, but unstaked tokens, keyed by the day number since epoch
    mapping(uint256 => uint256) public pendingStakes;
    /// @notice Last time pending stakes were deposited
    uint256 lastStakeTimestamp;
    /// @notice The total amount of staked token
    uint256 public totalStaked;
    /// @notice The amount of tokens staked by an account
    mapping(address => uint256) public userStake;
    /// @notice The amount of tokens owed to a user who's deposited.
    mapping(address => int256) public rewardDebts;
    /// @notice All stakes currently active
    Stake[] public stakes;
    /// @notice Deposit ID of last stake. Also tracked in atlas mine
    uint256 lastDepositId;
    /// @notice Total MAGIC rewards earned by staking.
    uint256 totalRewardsEarned;
    /// @notice Rewards accumulated per share
    uint256 accRewardsPerShare;

    // ============= Operator State ==============

    /// @notice Fee to contract operator. Only assessed on rewards.
    uint256 public fee;
    /// @notice Amount of fees reserved for withdrawal by the operator.
    uint256 public feeReserve;
    /// @notice Max fee the owner can ever take - 10%
    uint256 public constant MAX_FEE = 1000;

    uint256 public constant FEE_DENOMINATOR = 10000;

    // ========================================== CONSTRUCTOR ===========================================

    /**
     * @param _mine                 The AtlasMine contract.
     * @param _lock                 The locking strategy of the staknig pool.
     *                              Maps to a timelock for AtlasMine deposits.
     */
    constructor(
        address _magic,
        AtlasMine _mine,
        AtlasMine.Lock _lock
    ) {
        magic = _magic;
        mine = _mine;

        /// @notice each staker cycles its locks for a predefined amount. New
        ///         lock cycle, new contract.
        lock = _lock;

        lastStakeTimestamp = block.timestamp;

        // Approve the mine
        IERC20(magic).safeApprove(address(mine), 2**256 - 1);
    }

    // ======================================== USER OPERATIONS ========================================

    /**
     * @notice Make a new depoit into the Staker. The Staker will collect
     *         the tokens, to be later staked in atlas mine by the owner,
     *         according to the stake/unlock schedule.
     * @dev    Specified amount of token must be approved by the caller.
     *
     * @param _amount               The amount of tokens to deposit.
     */
    function deposit(uint256 _amount) public virtual override {
        require(_amount > 0, "Deposit amount 0");

        if (_totalControlledMagic() > 0) {
            uint256 proRataMagicWithPrecision = (_amount * ONE) / _totalControlledMagic();
            uint256 proRataMagic = proRataMagicWithPrecision / ONE;
            require(proRataMagic > 0, "Deposit too small");
        }

        _updateRewards();

        // Update accounting
        userStake[msg.sender] += _amount;
        totalStaked += _amount;
        rewardDebts[msg.sender] = ((_amount * accRewardsPerShare) / ONE).toInt256();

        uint256 day = _getDay(block.timestamp);
        pendingStakes[day] += _amount;

        // Collect tokens
        IERC20(magic).safeTransferFrom(msg.sender, address(this), _amount);

        // MAGIC tokens sit in contract. Added to pending stakes
        emit UserDeposit(msg.sender, _amount);
    }

    /**
     * @notice Withdraw a deposit from the Staker contract. Calculates
     *         pro rata share of accumulated MAGIC and distributes any
     *         earned rewards in addition to original deposit.
     *         There must be enough unlocked tokens to withdraw.
     *
     */
    function withdraw() public virtual override {
        // Update accounting
        uint256 amount = userStake[msg.sender];
        require(amount > 0, "No deposit");

        userStake[msg.sender] -= amount;
        totalStaked -= amount;
        int256 rewardDebt = rewardDebts[msg.sender];

        // Distribute tokens
        _updateRewards();

        // Unstake if we need to to ensure we can withdraw
        int256 accumulatedRewards = ((amount * accRewardsPerShare) / ONE).toInt256();
        uint256 reward = (accumulatedRewards - rewardDebt).toUint256();
        uint256 payout = amount + reward;

        rewardDebts[msg.sender] = ((amount * accRewardsPerShare) / ONE).toInt256();

        // If we need to unstake, unstake until we have enough
        if (payout > _totalUsableMagic()) {
            _unstakeToTarget(payout);
        }

        IERC20(magic).safeTransfer(msg.sender, payout);

        emit UserWithdraw(msg.sender, amount, reward);
    }

    /**
     * @notice Claim rewards without unstaking. Will fail if there
     *         are not enough tokens in the contract to claim rewards.
     *         Does not attempt to unstake.
     *
     */
    function claim() public virtual override {
        // Update accounting
        uint256 amount = userStake[msg.sender];
        int256 rewardDebt = rewardDebts[msg.sender];
        rewardDebts[msg.sender] -= ((amount * accRewardsPerShare) / ONE).toInt256();

        // Distribute tokens
        _updateRewards();

        // Unstake if we need to to ensure we can withdraw
        int256 accumulatedRewards = ((amount * accRewardsPerShare) / ONE).toInt256();
        uint256 reward = (accumulatedRewards - rewardDebt).toUint256();

        require(reward <= _totalUsableMagic(), "Not enough rewards to claim");

        IERC20(magic).safeTransfer(msg.sender, reward);

        emit UserClaim(msg.sender, reward);
    }

    /**
     * @notice Works similarly to withdraw, but does not attempt to claim rewards.
     *         Used in case there is an issue with rewards calculation either here or
     *         in the Atlas Mine. emergencyUnstakeAllFromMine should be called before this,
     *         since it does not attempt to unstake.
     *
     */
    function withdrawEmergency() public virtual override {
        require(schedulePaused, "Not in emergency state");

        uint256 amount = userStake[msg.sender];
        userStake[msg.sender] -= amount;
        totalStaked -= amount;

        require(amount <= _totalUsableMagic(), "Not enough unstaked");

        IERC20(magic).safeTransfer(msg.sender, amount);

        emit UserWithdraw(msg.sender, amount, 0);
    }

    /**
     * @notice Stake any pending stakes before the current day. Callable
     *         by anybody. Any pending stakes will unlock according
     *         to the time this method is called, and the contract's defined
     *         lock time.
     */
    function stakeScheduled() public virtual override {
        require(!schedulePaused, "new staking paused");

        uint256 currentDay = _getDay(block.timestamp);
        uint256 lastDay = _getDay(lastStakeTimestamp);
        lastStakeTimestamp = block.timestamp;

        (, uint256 locktime) = mine.getLockBoost(lock);
        uint256 unlockAt = block.timestamp + locktime;

        uint256 amountToStake = 0;

        // Do not stake current day - only days in the past
        for (uint256 i = lastDay; i < currentDay; i++) {
            // Stake pending stake for that day and stop tracking it
            amountToStake += pendingStakes[i];
            delete pendingStakes[i];
        }

        _stakeInMine(amountToStake);
        emit MineStake(amountToStake, unlockAt);
    }

    // ======================================= HOARD OPERATIONS ========================================

    /**
     * @notice Stake a Treasure owned by the hoard into the Atlas Mine.
     *         Staked treasures will boost all user deposits.
     * @dev    Any treasure must be approved for withdrawal by the caller.
     *
     * @param _tokenId              The tokenId of the specified treasure.
     * @param _amount               The amount of treasures to stake.
     */
    function stakeTreasure(uint256 _tokenId, uint256 _amount) external override onlyHoard {
        // First withdraw and approve
        address treasureAddr = mine.treasure();
        IERC1155 treasure = IERC1155(treasureAddr);

        treasure.setApprovalForAll(address(mine), true);
        treasure.safeTransferFrom(msg.sender, address(this), _tokenId, _amount, bytes(""));

        mine.stakeTreasure(_tokenId, _amount);
        uint256 boost = mine.boosts(address(this));

        emit StakeNFT(treasureAddr, _tokenId, _amount, boost);
    }

    /**
     * @notice Unstake a Treasure from the Atlas Mine and return it to the hoard.
     *
     * @param _tokenId              The tokenId of the specified treasure.
     * @param _amount               The amount of treasures to stake.
     */
    function unstakeTreasure(uint256 _tokenId, uint256 _amount) external override onlyHoard {
        address treasureAddr = mine.treasure();
        IERC1155 treasure = IERC1155(treasureAddr);

        mine.unstakeTreasure(_tokenId, _amount);

        // Distribute to hoard
        treasure.safeTransferFrom(address(this), msg.sender, _tokenId, _amount, bytes(""));

        uint256 boost = mine.boosts(address(this));

        emit UnstakeNFT(treasureAddr, _tokenId, _amount, boost);
    }

    /**
     * @notice Stake a Legion owned by the hoard into the Atlas Mine.
     *         Staked legions will boost all user deposits.
     * @dev    Any legion be approved for withdrawal by the caller.
     *
     * @param _tokenId              The tokenId of the specified legion.
     */
    function stakeLegion(uint256 _tokenId) external override onlyHoard {
        // First withdraw and approve
        address legionAddr = mine.legion();
        IERC721 legion = IERC721(legionAddr);

        legion.safeTransferFrom(msg.sender, address(this), _tokenId);
        legion.setApprovalForAll(address(mine), true);

        mine.stakeLegion(_tokenId);

        uint256 boost = mine.boosts(address(this));

        emit StakeNFT(legionAddr, _tokenId, 1, boost);
    }

    /**
     * @notice Unstake a Legion from the Atlas Mine and return it to the hoard.
     *
     * @param _tokenId              The tokenId of the specified legion.
     */
    function unstakeLegion(uint256 _tokenId) external override onlyHoard {
        address legionAddr = mine.legion();
        IERC721 legion = IERC721(legionAddr);

        mine.unstakeLegion(_tokenId);

        // Distribute to hoard
        legion.safeTransferFrom(address(this), msg.sender, _tokenId);

        uint256 boost = mine.boosts(address(this));

        emit UnstakeNFT(legionAddr, _tokenId, 1, boost);
    }

    // ======================================= OWNER OPERATIONS =======================================

    /**
     * @notice Unstake everything eligible for unstaking from Atlas Mine.
     *         Callable by owner. Should only be used in case of emergency
     *         or migration to a new contract, or if there is a need to service
     *         an unexpectedly large amount of withdrawals.
     *
     *         If unlockAll is set to true in the Atlas Mine, this can withdraw
     *         all stake.
     */
    function unstakeAllFromMine() external override onlyOwner {
        // Unstake everything eligible

        for (uint256 i = 0; i < stakes.length; i++) {
            Stake memory s = stakes[i];

            if (s.unlockAt > block.timestamp) {
                // This stake is not unlocked - stop looking
                break;
            }

            // Withdraw position - auto-harvest
            _withdrawAndHarvestMine(s.depositId, s.amount);
            _updateStakeDepositAmount(i);
        }

        // Only check for removal after, so we don't mutate while looping
        _removeZeroStakes();
    }

    /**
     * @notice Let owner unstake a specified amount as needed to make sure the contract is funded.
     *         Can be used to faciliate expected future withdrawals.
     *
     * @param target                The amount of tokens to reclaim from the mine.
     */
    function unstakeToTarget(uint256 target) external override onlyOwner {
        _unstakeToTarget(target);
    }

    /**
     * @notice Works similarly to unstakeAllFromMine, but does not harvest
     *         rewards. Used for getting out original stake emergencies.
     *         Requires emergency flag - schedulePaused to be set. Does NOT
     *         take a fee on rewards.
     *
     *         Requires that everything gets withdrawn to make sure it is only
     *         used in emergency. If not the case, reverts.
     */
    function emergencyUnstakeAllFromMine() external override onlyOwner {
        require(schedulePaused, "Not in emergency state");

        // Unstake everything eligible
        mine.withdrawAll();
        _removeZeroStakes();

        require(stakes.length == 0, "Still active stakes");
    }

    /**
     * @notice Change the fee taken by the operator. Can never be more than
     *         MAX_FEE. Fees only assessed on rewards.
     *
     * @param _fee                  The fee, expressed in bps.
     */
    function setFee(uint256 _fee) external override onlyOwner {
        require(_fee <= MAX_FEE, "Invalid fee");

        fee = _fee;

        emit SetFee(fee);
    }

    /**
     * @notice Change the designated hoard, the address where treasures and
     *         legions are held. Staked NFTs can only be
     *         withdrawn to the current hoard address, regardless of which
     *         address hte hoard was set to when it was staked.
     *
     * @param _hoard                The new hoard address.
     */
    function setHoard(address _hoard) external override onlyOwner {
        require(_hoard != address(0), "Invalid hoard");

        hoard = _hoard;
    }

    /**
     * @notice Withdraw any accumulated reward fees to the contract owner.
     */
    function withdrawFees() external virtual override onlyOwner {
        uint256 amount = feeReserve;
        feeReserve = 0;

        IERC20(magic).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice EMERGENCY ONLY - toggle pausing new scheduled stakes.
     *         If on, users can deposit, but stakes won't go to Atlas Mine.
     *         Can be used in case of Atlas Mine issues or forced migration
     *         to new contract.
     */
    function toggleSchedulePause(bool paused) external virtual onlyOwner {
        schedulePaused = paused;

        emit StakingPauseToggle(paused);
    }

    // ======================================== VIEW FUNCTIONS =========================================

    /**
     * @notice Returns all magic either unstaked, staked, or pending rewards in Atlas Mine.
     *         Best proxy for TVL.
     *
     * @return total               The total amount of MAGIC in the staker.
     */
    function totalMagic() external view override returns (uint256) {
        return _totalControlledMagic() + mine.pendingRewardsAll(address(this));
    }

    /**
     * @notice Returns all magic that has been deposited, but not staked, and is eligible
     *         to be staked (deposit time < current day).
     *
     * @return total               The total amount of MAGIC available to stake.
     */
    function totalPendingStake() external view override returns (uint256) {
        uint256 pending = 0;

        uint256 currentDay = _getDay(block.timestamp);
        uint256 lastDay = _getDay(lastStakeTimestamp);

        // Do not count current day - only days in the past
        for (uint256 i = lastDay; i < currentDay; i++) {
            // Stake pending stake for that day
            pending += pendingStakes[i];
        }

        return pending;
    }

    /**
     * @notice Returns all magic that has been deposited, but not staked, and is eligible
     *         to be staked (deposit time < current day).
     *
     * @return total               The total amount of MAGIC that can be withdrawn
     */
    function totalWithdrawableMagic() external view override returns (uint256) {
        uint256 pendingRewards = mine.pendingRewardsAll(address(this));

        uint256 vestedPrincipal;
        for (uint256 i = 0; i < stakes.length; i++) {
            vestedPrincipal += mine.calcualteVestedPrincipal(address(this), stakes[i].depositId);
        }

        return _totalUsableMagic() + pendingRewards + vestedPrincipal;
    }

    // ============================================ HELPERS ============================================

    /**
     * @dev Stake tokens held by staker in the Atlas Mine, according to
     *      the predefined lock value. Schedules for staking will be managed by a queue.
     *
     * @param _amount               Number of tokens to stake
     */
    function _stakeInMine(uint256 _amount) internal {
        require(_amount <= _totalUsableMagic(), "Not enough funds");

        uint256 depositId = ++lastDepositId;

        (, uint256 locktime) = mine.getLockBoost(lock);
        uint256 unlockAt = block.timestamp + locktime;

        stakes.push(Stake({ amount: _amount, unlockAt: unlockAt, depositId: depositId }));

        mine.deposit(_amount, lock);
    }

    /**
     * @dev Unstakes until we have enough unstaked tokens to meet a specific target.
     *      Used to make sure we can service withdrawals.
     *
     * @param target                The amount of tokens we want to have unstaked.
     */
    function _unstakeToTarget(uint256 target) internal {
        uint256 unstaked = 0;

        for (uint256 i = 0; i < stakes.length; i++) {
            Stake memory s = stakes[i];

            if (s.unlockAt > block.timestamp) {
                // This stake is not unlocked - stop looking
                break;
            }

            // Withdraw position - auto-harvest
            uint256 preclaimBalance = _totalUsableMagic();
            uint256 targetLeft = target - unstaked;
            uint256 amount = targetLeft > s.amount ? s.amount : targetLeft;
            _withdrawAndHarvestMine(s.depositId, amount);
            uint256 postclaimBalance = _totalUsableMagic();

            // Increment amount unstaked
            unstaked += postclaimBalance - preclaimBalance;

            if (unstaked >= target) {
                // We unstaked enough
                break;
            }

            _updateStakeDepositAmount(i);
        }

        require(unstaked >= target, "Cannot unstake enough");
        require(_totalUsableMagic() >= target, "Not enough in contract after unstaking");

        // Only check for removal after, so we don't mutate while looping
        _removeZeroStakes();
    }

    /**
     * @dev Unstake a defined singular stake from the mine, up to a particular amount.
     *      Large _amounts get decreased down to the maximum amount of the stake.
     *      Not all stake amount may be withdrawn, depending on Atlas Mine vesting schedule.
     *
     * @param stakeIndex            The index of the stake to unstake from in the local Stakes array.
     * @param _amount               The amount to unstake.
     */
    function _unstakeSingleStakeFromMine(uint256 stakeIndex, uint256 _amount) internal {
        // Get deposit ID from stake
        require(stakeIndex < stakes.length, "Index out of bounds");

        Stake storage s = stakes[stakeIndex];
        require(s.unlockAt <= block.timestamp, "Stake still locked");

        if (_amount > s.amount) {
            _amount = s.amount;
        }

        // Withdraw position - auto-harvest
        _withdrawAndHarvestMine(s.depositId, _amount);

        uint256 amount = _updateStakeDepositAmount(stakeIndex);
        if (amount == 0) _removeStake(stakeIndex);
    }

    /**
     * @dev Harvest rewards from the AtlasMine and send them back to
     *      this contract.
     *
     * @return earned               The amount of rewards earned for depositors, minus the fee.
     * @return feeEearned           The amount of fees earned for the contract operator.
     */
    function _harvestMine() internal returns (uint256, uint256) {
        uint256 preclaimBalance = IERC20(magic).balanceOf(address(this));
        mine.harvestAll();
        uint256 postclaimBalance = IERC20(magic).balanceOf(address(this));

        uint256 earned = postclaimBalance - preclaimBalance;

        console.log("EARNED", earned);

        // Reserve the 'fee' amount of what is earned
        uint256 feeEarned = (earned * fee) / FEE_DENOMINATOR;
        feeReserve += feeEarned;

        emit MineHarvest(earned - feeEarned, feeEarned);

        return (earned - feeEarned, feeEarned);
    }

    /**
     * @dev Withdraw an amount from a designated deposit, also
     *      harvesting rewards.
     *
     * @param depositId             The depositId of the stake to withdraw.
     * @param amount                The amount of tokens to withdraw from the stake.
     *
     * @return earned               The amount of rewards earned for depositors, minus the fee.
     * @return feeEearned           The amount of fees earned for the contract operator.
     *
     */
    function _withdrawAndHarvestMine(uint256 depositId, uint256 amount) internal returns (uint256, uint256) {
        uint256 preclaimBalance = IERC20(magic).balanceOf(address(this));
        mine.withdrawAndHarvestPosition(depositId, amount);
        uint256 postclaimBalance = IERC20(magic).balanceOf(address(this));

        uint256 earned = postclaimBalance - preclaimBalance;

        // Reserve the 'fee' amount of what is earned
        uint256 feeEarned = (earned * fee) / FEE_DENOMINATOR;
        feeReserve += feeEarned;

        emit MineHarvest(earned - feeEarned, feeEarned);

        return (earned - feeEarned, feeEarned);
    }

    /**
     * @dev Harvest rewards from the mine so that stakers can claim.
     *      Recalculate how many rewards are distributed to each share.
     */
    function _updateRewards() internal {
        if (totalStaked == 0) return;

        (uint256 newRewards, ) = _harvestMine();
        totalRewardsEarned += newRewards;

        accRewardsPerShare += (newRewards * ONE) / totalStaked;
    }

    /**
     * @dev After mutating a stake (by withdrawing fully or partially),
     *      get updated data from the staking contract, and update the stake amounts
     *
     * @param stakeIndex           The index of the stake in the Stakes storage array.
     *
     * @return amount              The current, updated amount of the stake.
     */
    function _updateStakeDepositAmount(uint256 stakeIndex) internal returns (uint256) {
        Stake storage s = stakes[stakeIndex];

        (, uint256 depositAmount, , , , , ) = mine.userInfo(address(this), s.depositId);
        s.amount = depositAmount;

        return s.amount;
    }

    /**
     * @dev Find stakes with zero deposit amount and remove them from tracking.
     *      Uses recursion to stop from mutating an array we are currently looping over.
     *      If a zero stake is found, it is removed, and the function is restarted,
     *      such that it is always working from a 'clean' array.
     *
     */
    function _removeZeroStakes() internal {
        bool shouldRecurse = true;

        for (uint256 i = 0; i < stakes.length; i++) {
            Stake storage s = stakes[i];

            if (s.amount == 0) {
                _removeStake(i);
                // Stop looping and start again - we will skip
                // out of the look and recurse
                break;
            }

            if (i == stakes.length - 1) {
                // We didn't remove anything, so stop recursing
                shouldRecurse = false;
            }
        }

        if (shouldRecurse) {
            _removeZeroStakes();
        }
    }

    /**
     * @dev Calculate total amount of MAGIC usable by the contract.
     *      'Usable' means available for either withdrawal or re-staking.
     *      Counts unstaked magic less fee reserve.
     *
     * @return amount               The amount of usable MAGIC.
     */
    function _totalUsableMagic() internal view returns (uint256) {
        // Current magic held in contract
        uint256 unstaked = IERC20(magic).balanceOf(address(this));

        return unstaked - feeReserve;
    }

    /**
     * @dev Calculate total amount of MAGIC under control of the contract.
     *      Counts staked and unstaked MAGIC. Does _not_ count accumulated
     *      but unclaimed rewards.
     *
     * @return amount               The total amount of MAGIC under control of the contract.
     */
    function _totalControlledMagic() internal view returns (uint256) {
        // Current magic staked in mine
        uint256 staked = 0;

        for (uint256 i = 0; i < stakes.length; i++) {
            staked += stakes[i].amount;
        }

        return staked + _totalUsableMagic();
    }

    /**
     * @dev Remove a tracked stake from any position in the stakes array.
     *      Used when a stake is no longer relevant i.e. fully withdrawn.
     *      Mutates the Stakes array in storage.
     *
     * @param index                 The index of the stake to remove.
     */
    function _removeStake(uint256 index) internal {
        if (index >= stakes.length) return;

        for (uint256 i = index; i < stakes.length - 1; i++) {
            stakes[i] = stakes[i + 1];
        }

        delete stakes[stakes.length - 1];

        stakes.pop();
    }

    /**
     * @dev Get day number of timestamp since unix epoch
     *
     * @return day                  The day number.
     */
    function _getDay(uint256 timestamp) internal pure returns (uint256) {
        return timestamp / 86400;
    }

    /**
     * @dev For methods only callable by the hoard - Treasure staking/unstaking.
     */
    modifier onlyHoard() {
        require(msg.sender == hoard, "Not hoard");

        _;
    }
}
