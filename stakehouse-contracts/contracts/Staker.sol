// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "hardhat/console.sol";

/**
  @title An asset staking contract.
  @author Tim Clancy

  This staking contract disburses tokens from its internal reservoir according
  to a fixed emission schedule. Assets can be assigned varied staking weights.
  This code is inspired by and modified from Sushi's Master Chef contract.
  https://github.com/sushiswap/sushiswap/blob/master/contracts/MasterChef.sol
*/
contract Staker is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // A user-specified, descriptive name for this Staker.
  string public name;

  // The token to disburse.
  IERC20 public token;

  // The amount of the disbursed token deposited by users. This is used for the
  // special case where a staking pool has been created for the disbursed token.
  // This is required to prevent the Staker itself from reducing emissions.
  uint256 public totalTokenDeposited;

  // A flag signalling whether the contract owner can add or set developers.
  bool public canAlterDevelopers;

  // An array of developer addresses for finding shares in the share mapping.
  address[] public developerAddresses;

  // A mapping of developer addresses to their percent share of emissions.
  // Share percentages are represented as 1/1000th of a percent. That is, a 1%
  // share of emissions should map an address to 1000.
  mapping (address => uint256) public developerShares;

  // A flag signalling whether or not the contract owner can alter emissions.
  bool public canAlterEmissionSchedule;

  // An array of emission schedule key blocks for finding emission rate changes.
  uint256[] public emissionBlocks;

  // Store the very earliest possible emission block for quick reference.
  uint256 MAX_INT = 2**256 - 1;
  uint256 public earliestEmissionBlock;

  // The token emission schedule of the Staker. This emission schedule maps a
  // block number to the amount of token that should be disbursed with every
  // block beginning at said block number.
  mapping (uint256 => uint256) public emissionSchedule;

  // Information for each pool that can be staked in.
  // - token: the address of the ERC20 asset that is being staked in the pool.
  // - strength: the relative token emission strength of this pool.
  // - lastRewardBlock: the last block number where token distribution occurred.
  // - tokensPerShare: accumulated tokens per share times 1e12.
  // - pointsPerShare: accumulated points per share times 1e12.
  struct PoolInfo {
    IERC20 token;
    uint256 strength;
    uint256 lastRewardBlock;
    uint256 tokensPerShare;
  }

  IERC20[] public poolTokens;

  // Stored information for each available pool per its token address.
  mapping (IERC20 => PoolInfo) public poolInfo;

  // Information for each user per staking pool:
  // - amount: the amount of the pool asset being provided by the user.
  // - rewardDebt: the value of the user's total earning that has been paid out.
  // -- pending reward = (user.amount * pool.tokensPerShare) - user.rewardDebt.
  struct UserInfo {
    uint256 amount;
    uint256 rewardPaid;
  }

  // Stored information for each user staking in each pool.
  mapping (IERC20 => mapping (address => UserInfo)) public userInfo;

  // The total sum of the strength of all pools.
  uint256 public totalStrength;

  // The total amount of the disbursed token ever emitted by this Staker.
  uint256 public totalTokenDisbursed;

  // Users additionally accrue non-token points for participating via staking.
  mapping (address => uint256) public userPoints;
  mapping (address => uint256) public userSpentPoints;

  // A map of all external addresses that are permitted to spend user points.
  mapping (address => bool) public approvedPointSpenders;

  // Events for depositing assets into the Staker and later withdrawing them.
  event Deposit(address indexed user, IERC20 indexed token, uint256 amount);
  event Withdraw(address indexed user, IERC20 indexed token, uint256 amount);

  // An event for tracking when a user has spent points.
  event SpentPoints(address indexed source, address indexed user, uint256 amount);

  /**
    Construct a new Staker by providing it a name and the token to disburse.
    @param _name The name of the Staker contract.
    @param _token The token to reward stakers in this contract with.
  */
  constructor(string memory _name, IERC20 _token) public {
    name = _name;
    token = _token;
    token.approve(address(this), MAX_INT);
    canAlterDevelopers = true;
    canAlterEmissionSchedule = true;
    earliestEmissionBlock = MAX_INT;
  }

  /**
    Add a new developer to the Staker or overwrite an existing one.
    This operation requires that developer address addition is not locked.
    @param _developerAddress The additional developer's address.
    @param _share The share in 1/1000th of a percent of each token emission sent
    to this new developer.
  */
  function addDeveloper(address _developerAddress, uint256 _share) public onlyOwner {
    require(canAlterDevelopers,
      "This Staker has locked the addition of developers; no more may be added.");
    developerAddresses.push(_developerAddress);
    developerShares[_developerAddress] = _share;
  }

  /**
    Permanently forfeits owner ability to alter the state of Staker developers.
    Once called, this function is intended to give peace of mind to the Staker's
    developers and community that the fee structure is now immutable.
  */
  function lockDevelopers() public onlyOwner {
    canAlterDevelopers = false;
  }

  /**
    A developer may at any time update their address or voluntarily reduce their
    share of emissions by calling this function from their current address.
    Note that updating a developer's share to zero effectively removes them.
    @param _newDeveloperAddress An address to update this developer's address.
    @param _newShare The new share in 1/1000th of a percent of each token
    emission sent to this developer.
  */
  function updateDeveloper(address _newDeveloperAddress, uint256 _newShare) public {
    uint256 developerShare = developerShares[msg.sender];
    require(developerShare > 0,
      "You are not a developer of this Staker.");
    require(_newShare <= developerShare,
      "You cannot increase your developer share.");
    developerShares[msg.sender] = 0;
    developerAddresses.push(_newDeveloperAddress);
    developerShares[_newDeveloperAddress] = _newShare;
  }

  /**
    Add new emission details to the Staker or overwrite existing ones.
    This operation requires that emission schedule alteration is not locked.
    @param _blockNumbers An array of block numbers to key associated rates to.
    @param _rates An array of emission rates for the corresponding blocks.
  */
  function addEmissions(uint256[] memory _blockNumbers, uint256[] memory _rates) public onlyOwner {
    require(canAlterEmissionSchedule,
      "This Staker has locked the alteration of emissions.");
    require(_blockNumbers.length == _rates.length,
      "Your emission data arrays must be of equal length.");
    for (uint256 i = 0; i < _blockNumbers.length; ++i) {
      uint256 blockNumber = _blockNumbers[i];
      if (earliestEmissionBlock > blockNumber) {
        earliestEmissionBlock = blockNumber;
      }
      uint256 rate = _rates[i];
      emissionBlocks.push(blockNumber);
      emissionSchedule[blockNumber] = rate;
    }
  }

  /**
    Permanently forfeits owner ability to alter the emission schedule.
    Once called, this function is intended to give peace of mind to the Staker's
    developers and community that the inflation rate is now immutable.
  */
  function lockEmissions() public onlyOwner {
    canAlterEmissionSchedule = false;
  }

  /**
    Returns the length of the developer address array.
    @return the length of the developer address array.
  */
  function getDeveloperCount() external view returns (uint256) {
    return developerAddresses.length;
  }

  /**
    Returns the length of the emission blocks array.
    @return the length of the emission blocks array.
  */
  function getEmissionBlockCount() external view returns (uint256) {
    return emissionBlocks.length;
  }

  /**
    Returns the length of the staking pool array.
    @return the length of the staking pool array.
  */
  function getPoolCount() external view returns (uint256) {
    return poolTokens.length;
  }

  /**
    Returns the amount of token that has not been disbursed by the Staker yet.
    @return the amount of token that has not been disbursed by the Staker yet.
  */
  function getRemainingToken() external view returns (uint256) {
    return token.balanceOf(address(this));
  }

  /**
    Allows the contract owner to add a new asset pool to the Staker or overwrite
    an existing one.
    @param _token The address of the asset to base this staking pool off of.
    @param _strength The relative strength of the new asset.
  */
  function addPool(IERC20 _token, uint256 _strength) public onlyOwner {
    require(emissionBlocks.length > 0,
      "Staking pools cannot be addded until an emission schedule has been defined.");
    uint256 lastRewardBlock = block.number > earliestEmissionBlock ? block.number : earliestEmissionBlock;
    if (address(poolInfo[_token].token) == address(0)) {
      poolTokens.push(_token);
      totalStrength = totalStrength.add(_strength);
      poolInfo[_token] = PoolInfo({
        token: _token,
        strength: _strength,
        lastRewardBlock: lastRewardBlock,
        tokensPerShare: 0
      });
    } else {
      totalStrength = totalStrength.sub(poolInfo[_token].strength).add(_strength);
      poolInfo[_token].strength = _strength;
    }
  }

  /**
    Uses the emission schedule to calculate the total amount of staking reward
    token that was emitted between two specified block numbers.
    @param _fromBlock The block to begin calculating emissions from.
    @param _toBlock The block to calculate total emissions up to.
  */
  function getTotalEmittedTokens(uint256 _fromBlock, uint256 _toBlock) public view returns (uint256) {
    require(_toBlock >= _fromBlock,
      "Tokens cannot be emitted from a higher block to a lower block.");
    uint256 totalEmittedTokens = 0;
    uint256 workingRate = 0;
    uint256 workingBlock = _fromBlock;
    for (uint256 i = 0; i < emissionBlocks.length; ++i) {
      uint256 emissionBlock = emissionBlocks[i];
      uint256 emissionRate = emissionSchedule[emissionBlock];
      if (_toBlock < emissionBlock) {
        totalEmittedTokens = totalEmittedTokens.add(_toBlock.sub(workingBlock).mul(workingRate));
        return totalEmittedTokens;
      } else if (workingBlock < emissionBlock) {
        totalEmittedTokens = totalEmittedTokens.add(emissionBlock.sub(workingBlock).mul(workingRate));
        workingBlock = emissionBlock;
      }
      workingRate = emissionRate;
    }
    if (workingBlock < _toBlock) {
      totalEmittedTokens = totalEmittedTokens.add(_toBlock.sub(workingBlock).mul(workingRate));
    }
    return totalEmittedTokens;
  }

  /**
    Update the pool corresponding to the specified token address.
    @param _token The address of the asset to update the corresponding pool for.
  */
  function updatePool(IERC20 _token) public {
    PoolInfo storage pool = poolInfo[_token];
    if (block.number <= pool.lastRewardBlock) {
      return;
    }
    uint256 poolTokenSupply = pool.token.balanceOf(address(this));
    if (address(_token) == address(token)) {
      poolTokenSupply = totalTokenDeposited;
    }
    if (poolTokenSupply <= 0) {
      pool.lastRewardBlock = block.number;
      return;
    }

    // Calculate tokens and point rewards for this pool.
    uint256 totalEmittedTokens = getTotalEmittedTokens(pool.lastRewardBlock, block.number);
    uint256 tokensReward = totalEmittedTokens.mul(pool.strength).div(totalStrength).mul(1e12);
    uint256 pointsReward = tokensReward.mul(100);

    // Directly pay developers their corresponding share of tokens and points.
    for (uint256 i = 0; i < developerAddresses.length; ++i) {
      address developer = developerAddresses[i];
      uint256 share = developerShares[developer];
      uint256 devTokens = tokensReward.mul(share).div(100000);
      tokensReward = tokensReward - devTokens;
      uint256 devPoints = pointsReward.mul(share).div(100000);
      pointsReward = pointsReward - devPoints;
      token.safeTransferFrom(address(this), developer, devTokens.div(1e12));
      userPoints[developer] = devPoints.div(1e12);
    }

    // Update the pool rewards per share to pay users the amount remaining.
    pool.tokensPerShare = pool.tokensPerShare.add(tokensReward.div(poolTokenSupply));
    pool.lastRewardBlock = block.number;
  }

  /**
    A function to easily see the amount of token rewards pending for a user on a
    given pool. Returns the pending reward token amount.
    @param _token The address of a particular staking pool asset to check for a
    pending reward.
    @param _user The user address to check for a pending reward.
    @return the pending reward token amount.
  */
  function pendingTokens(IERC20 _token, address _user) public view returns (uint256) {
    PoolInfo storage pool = poolInfo[_token];
    UserInfo storage user = userInfo[_token][_user];
    uint256 tokensPerShare = pool.tokensPerShare;
    uint256 poolTokenSupply = pool.token.balanceOf(address(this));
    if (address(_token) == address(token)) {
      poolTokenSupply = totalTokenDeposited;
    }

    if (block.number > pool.lastRewardBlock && poolTokenSupply > 0) {
      uint256 totalEmittedTokens = getTotalEmittedTokens(pool.lastRewardBlock, block.number);
      uint256 tokensReward = totalEmittedTokens.mul(pool.strength).div(totalStrength).mul(1e12);
      tokensPerShare = tokensPerShare.add(tokensReward.div(poolTokenSupply));
    }

    return user.amount.mul(tokensPerShare).div(1e12).sub(user.rewardPaid);
  }

  /**
    Return the number of points that the user has available to spend.
    @return the number of points that the user has available to spend.
  */
  function getAvailablePoints(address _user) public view returns (uint256) {
    uint256 concreteTotal = userPoints[_user];
    uint256 pendingTotal = 0;
    for (uint256 i = 0; i < poolTokens.length; ++i) {
      IERC20 poolToken = poolTokens[i];
      uint256 _pendingTokens = pendingTokens(poolToken, _user);
      pendingTotal = pendingTotal.add(_pendingTokens).div(1e16);
    }
    uint256 spentTotal = userSpentPoints[_user];
    return concreteTotal.add(pendingTotal).sub(spentTotal);
  }

  /**
    Return the total number of points that the user has ever accrued.
    @return the total number of points that the user has ever accrued.
  */
  function getTotalPoints(address _user) public view returns (uint256) {
    uint256 concreteTotal = userPoints[_user];
    uint256 pendingTotal = 0;
    for (uint256 i = 0; i < poolTokens.length; ++i) {
      IERC20 poolToken = poolTokens[i];
      uint256 _pendingTokens = pendingTokens(poolToken, _user);
      pendingTotal = pendingTotal.add(_pendingTokens).div(1e16);
    }
    return concreteTotal.add(pendingTotal);
  }

  /**
    Return the total number of points that the user has ever spent.
    @return the total number of points that the user has ever spent.
  */
  function getSpentPoints(address _user) public view returns (uint256) {
    return userSpentPoints[_user];
  }

  /**
    Deposit some particular assets to a particular pool on the Staker.
    @param _token The asset to stake into its corresponding pool.
    @param _amount The amount of the provided asset to stake.
  */
  function deposit(IERC20 _token, uint256 _amount) public {
    PoolInfo storage pool = poolInfo[_token];
    require(pool.strength > 0,
      "You cannot deposit assets into an inactive pool.");
    UserInfo storage user = userInfo[_token][msg.sender];
    updatePool(_token);
    if (user.amount > 0) {
      uint256 pending = user.amount.mul(pool.tokensPerShare).div(1e12).sub(user.rewardPaid);
      token.safeTransferFrom(address(this), msg.sender, pending);
      totalTokenDisbursed = totalTokenDisbursed.add(pending);
      userPoints[msg.sender] = userPoints[msg.sender].add(pending.div(1e16));
    }
    pool.token.safeTransferFrom(address(msg.sender), address(this), _amount);
    if (address(_token) == address(token)) {
      totalTokenDeposited = totalTokenDeposited.add(_amount);
    }
    user.amount = user.amount.add(_amount);
    user.rewardPaid = user.amount.mul(pool.tokensPerShare).div(1e12);
    emit Deposit(msg.sender, _token, _amount);
  }

  /**
    Withdraw some particular assets from a particular pool on the Staker.
    @param _token The asset to withdraw from its corresponding staking pool.
    @param _amount The amount of the provided asset to withdraw.
  */
  function withdraw(IERC20 _token, uint256 _amount) public {
    PoolInfo storage pool = poolInfo[_token];
    UserInfo storage user = userInfo[_token][msg.sender];
    require(user.amount >= _amount,
      "You cannot withdraw that much of the specified token; you are not owed it.");
    updatePool(_token);
    uint256 pending = user.amount.mul(pool.tokensPerShare).div(1e12).sub(user.rewardPaid);
    token.safeTransferFrom(address(this), msg.sender, pending);
    totalTokenDisbursed = totalTokenDisbursed.add(pending);
    userPoints[msg.sender] = userPoints[msg.sender].add(pending.div(1e16));
    if (address(_token) == address(token)) {
      totalTokenDeposited = totalTokenDeposited.sub(_amount);
    }
    user.amount = user.amount.sub(_amount);
    user.rewardPaid = user.amount.mul(pool.tokensPerShare).div(1e12);
    pool.token.safeTransfer(address(msg.sender), _amount);
    emit Withdraw(msg.sender, _token, _amount);
  }

  /**
    Allows the owner of this Staker to grant or remove approval to an external
    spender of the points that users accrue from staking resources.
    @param _spender The external address allowed to spend user points.
    @param _approval The updated user approval status.
  */
  function approvePointSpender(address _spender, bool _approval) public onlyOwner {
    approvedPointSpenders[_spender] = _approval;
  }

  /**
    Allows an approved spender of points to spend points on behalf of a user.
    @param _user The user whose points are being spent.
    @param _amount The amount of the user's points being spent.
  */
  function spendPoints(address _user, uint256 _amount) public {
    require(approvedPointSpenders[msg.sender],
      "You are not permitted to spend user points.");
    uint256 _userPoints = getAvailablePoints(_user);
    require(_userPoints >= _amount,
      "The user does not have enough points to spend the requested amount.");
    userSpentPoints[_user] = userSpentPoints[_user].add(_amount);
    emit SpentPoints(msg.sender, _user, _amount);
  }
}
