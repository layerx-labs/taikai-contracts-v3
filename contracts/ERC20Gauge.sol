// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC721URIStorage } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Metadata } from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import { ERC721Enumerable } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/**
 * @title Gauge contract to distribute rewards to ERC20 Stakers

 * @author Helder Vasconcelos <helder@layex.xyz>
 * @notice Gauge contract for distributing rewards to ERC20 Staker
 *
 * it accepts deposits and withdrawals of staking tokens (ERC20) and distributes rewards to the stakers (ERC20)
 * When the user deposits the tokens receives Gauge tokens (ERC20)
 * When the user withdraws the tokens the Gauge tokens are burned and the user receives the staking tokens
 * The rewards are distributed based on the Gauge tokens balance
 */
contract ERC20Gauge is ERC721Enumerable, Ownable {

  using SafeERC20 for IERC20;
  /**
   * @notice Event emitted when a deposit is made
   */
  event Deposit(address indexed from, address indexed receiver, uint256 amount, uint256 time);
  /**
   * @notice Event emitted when a withdraw is made
   */
  event Withdraw(address indexed owner, address indexed receiver, uint256 amount);
  /**
   * @notice Error emitted when the balance is invalid
   */
  error Gauge__InvalidBalance();
  /**
   * @notice Error emitted when the token is invalid
   */
  error Gauge__InvalidToken();
  /**
   * @notice Error emitted when the reward rate is invalid
   */
  error Gauge__InvalidRewardRate();
  /**
   * @notice Error emitted when the amount is zero
   */
  error Gauge__ZeroAmount();
  /**
   * @notice Error emitted when the duration is invalid
   */
  error Gauge__InvalidDuration();
  /**
   * @notice Error emitted when the NFT is invalid
   */
  error Gauge__InvalidNFT();
  /**
   * @notice Error emitted when the user is not the owner
   */
  error Gauge__NotOwner();
  /**
   * @notice Error emitted when the NFT is not unlocked
   */
  error Gauge__NotUnlocked();

  /**
   * @notice Struct to store the lock NFT Details
   */
  struct Lock {
    uint256 amount;
    uint256 shares;
    uint256 boostingFactor;
    uint256 unlockTime;
  }
  /**
   * @notice Constants for the boosting factor and the lock duration
   */
  uint256 constant ONE_HUNDRED_PERCENT = 100;
  uint256 constant ONE_TEN_PERCENT = 110;
  uint256 constant ONE_TWENTY_PERCENT = 120;
  uint256 constant ONE_THIRTY_PERCENT = 130;
  uint256 constant ONE_FOURTY_PERCENT = 140;
  uint256 constant ONE_FIFTY_PERCENT = 150;
  uint256 constant ONE_SIXTY_PERCENT = 160;
  uint256 constant ONE_SEVENTY_PERCENT = 170;

  uint256 constant ONE_MONTH = 30 days;
  uint256 constant THREE_MONTHS = 3 * ONE_MONTH;
  uint256 constant SIX_MONTHS = 6 * ONE_MONTH;
  uint256 constant TWELVE_MONTHS = 12 * ONE_MONTH;
  uint256 constant TWENTY_FOUR_MONTHS = 24 * ONE_MONTH;
  uint256 constant FOURTY_EIGHT_MONTHS = 48 * ONE_MONTH;

  uint256 internal constant PRECISION = 10 ** 18;
  uint256 internal constant BOOST_PRECISION = 100;

  /// @notice Address of the pool LP token which is deposited (staked) for rewards
  IERC20 private immutable _stakingToken;

  /// @notice Address of the reward token
  IERC20 private immutable _rewardToken;

  /// @notice Timestamp at which the reward rate starts
  uint256 private immutable _rewardStartTimestamp;

  /// @notice Timestamp at which the reward rate ends
  uint256 private immutable _rewardEndTimestamp;

  /// @notice Mapping of a NFT ID their reward amount
  mapping(uint256 => uint256) private _rewards;

  /// @notice Mapping of NFT ID to the amount of reward token they have been paid per token
  mapping(uint256 => uint256) private _nftsRewardPerTokenPaid;

  /// @notice Reward tokens per second
  uint256 private _rewardRate;

  /// @notice Last time rewards were updated
  uint256 private _lastUpdateTime;

  /// @notice Reward tokens per token
  uint256 private _rewardPerTokenStored;

  /// @notice Mapping of user address to their lock details
  uint256 private _totalShares;

  /// @notice Mapping of NFT ID to lock details
  mapping(uint256 => Lock) public _locksPerNft;

  uint256 private _totalLocked = 0;

  /// @notice Counter for NFT IDs
  uint256 private _nftIdCounter = 1;

  constructor(
    string memory name,
    string memory symbol,
    address owner,
    IERC20 stakingToken,
    IERC20 rewardToken,
    uint256 initialRewardRate,
    uint256 duration // in seconds
  ) ERC721(name, symbol) Ownable() {
    _transferOwnership(owner);
    _stakingToken = stakingToken;
    _rewardToken = rewardToken;
    _rewardRate = initialRewardRate;
    _rewardStartTimestamp = block.timestamp;
    _rewardEndTimestamp = block.timestamp + duration;
    // Validate reward rate
    if (_rewardRate == 0) revert Gauge__InvalidRewardRate();
    // Validate token addresses
    if (_stakingToken == IERC20(address(0)) || _rewardToken == IERC20(address(0)))
      revert Gauge__InvalidToken();
    //Validate reward duration
    if (duration == 0) revert Gauge__InvalidDuration();
    // Validate that we have enough balance to start the reward rate
    //if (balanceOf(address(this)) < initialRewardRate * duration) revert Gauge__InvalidBalance();
  }

  /**
   * @dev Calculates the reward per token based on the current block timestamp and the last update time.
   *
   * This function first checks if the total supply of tokens is zero. If it is, it returns the stored reward per token.
   * If the total supply is not zero, it calculates the reward per token by adding the reward accrued since the last update
   * to the stored reward per token. The reward accrued is calculated by multiplying the time elapsed since the last update
   * by the reward rate and then dividing by the total supply.
   *
   * Mathematically, this can be represented as:
   *
   * rewardPerToken = _rewardPerTokenStored + ((block.timestamp - _lastUpdateTime) * _rewardRate * 1e18) / totalSupply()
   *
   * where:
   * - rewardPerToken is the reward per token to be returned
   * - _rewardPerTokenStored is the stored reward per token
   * - block.timestamp is the current block timestamp
   * - _lastUpdateTime is the timestamp of the last update
   * - _rewardRate is the reward rate per second
   * - 1e18 is a scaling factor to convert the reward rate from per second to per token
   * - totalSupply() is the total supply of tokens
   *
   * @return The reward per token.
   */
  function rewardPerToken() public view returns (uint256) {
    if (_totalShares == 0) {
      return _rewardPerTokenStored;
    }
    return
      _rewardPerTokenStored +
      ((lastTimeRewardApplicable() - _lastUpdateTime) * _rewardRate * 1e18) /
      _totalShares;
  }

  function lastTimeRewardApplicable() public view returns (uint256) {
    return Math.min(block.timestamp, _rewardEndTimestamp);
  }

  /**
   * @dev Calculates the earned reward for a given account based on the balance of the account,
   * the reward per token, and the user's reward per token paid.
   *
   * @param nftId The nft of the account to calculate the earned reward for.
   * @return The earned reward for the account.
   */
  function earned(uint256 nftId) public view returns (uint256) {
    Lock memory lock = _locksPerNft[nftId];
    return
      (lock.shares * (rewardPerToken() - _nftsRewardPerTokenPaid[nftId])) /
      PRECISION +
      _rewards[nftId];
  }

  /**
   * @dev Deposits an amount of tokens into the gauge.
   *
   * @param amount The amount of tokens to deposit.
   */
  function deposit(
    address receiver,
    uint256 amount,
    uint256 time
  ) external returns (uint256 nftId) {
    if (amount == 0) revert Gauge__ZeroAmount();

    uint256 tokenId = _nftIdCounter; // Get the current token ID

    updateReward(tokenId);
    // Mint the amount of tokens to the sender
    nftId = _mintNFT(receiver, amount, time);

    _totalLocked += amount;
    // Transfer the amount of tokens from the sender to the gauge
    IERC20(_stakingToken).safeTransferFrom(msg.sender, address(this), amount);

    emit Deposit(msg.sender, receiver, amount, time);
  }

  /**
   * @notice Internal function to mint a new NFT
   * @param to The address to mint the NFT to
   * @param amount The amount of tokens to mint
   * @param time The duration of the lock
   * @return The ID of the minted NFT
   */
  function _mintNFT(address to, uint256 amount, uint256 time) internal returns (uint256) {
    uint256 tokenId = _nftIdCounter; // Get the current token ID
    _mint(to, tokenId); // Mint the NFT

    (uint256 fixedDuration, uint256 boostingFactor) = getBoostingFactor(time);

    uint256 shares = (amount * boostingFactor) / BOOST_PRECISION;

    Lock storage lock = _locksPerNft[tokenId];
    lock.amount = amount;
    lock.shares = shares;
    lock.boostingFactor = boostingFactor;
    lock.unlockTime = block.timestamp + fixedDuration;
    _totalShares += shares;

    // Set the UR
    _nftIdCounter++; // Increment the token ID counter
    return tokenId; // Return the token ID
  }

  /**
   * @dev Withdraws an amount of tokens from the gauge.
   *
   * @param nftId The NFT ID of the lock to withdraw.
   */
  function withdraw(uint256 nftId, address receiver) external {
    // Validate the token ID
    if (nftId < 1 || nftId >= _nftIdCounter) revert Gauge__InvalidNFT();
    // Validate the amount
    if (_locksPerNft[nftId].amount == 0) revert Gauge__ZeroAmount();
    // Validate the owner of the token
    if (msg.sender != ownerOf(nftId)) revert Gauge__NotOwner();
    // Validate the unlock time
    if (_locksPerNft[nftId].unlockTime > block.timestamp) revert Gauge__NotUnlocked();



    updateReward(nftId);

    _totalShares -= _locksPerNft[nftId].shares;

    uint256 amount = _locksPerNft[nftId].amount;

    _totalLocked -= amount;

    delete _locksPerNft[nftId];

    _burn(nftId);
    // Transfer the amount of tokens from the gauge to the sender
    IERC20(_stakingToken).safeTransfer(receiver, amount);

    emit Withdraw(msg.sender, receiver, amount);
  }

  /**
   * @dev Claims the earned rewards for the sender.
   */

  function claimRewards(uint256 nftId) public {
    updateReward(nftId);
    address account = ownerOf(nftId);
    uint256 reward = _rewards[nftId];
    if (reward > 0) {
      _rewards[nftId] = 0;
      _rewardToken.safeTransfer(account, reward);
    }
  }
  /**
   * @notice Claims all rewards for a given address
   * @param account The address to claim rewards for
   */
  function claimAllRewards(address account) public {
    for (uint256 i = 0; i < balanceOf(account); i++) {
      uint256 nftId = tokenOfOwnerByIndex(account, i);
      claimRewards(nftId);
    }
  }

  /**
   * @dev Updates the reward for a given account.
   *
   * @param nftId The address of the account to update the reward for.
   */
  function updateReward(uint256 nftId) internal {
    _rewardPerTokenStored = rewardPerToken();
    _lastUpdateTime = lastTimeRewardApplicable();

    if (nftId == 0) {
      _rewards[nftId] = earned(nftId);
      _nftsRewardPerTokenPaid[nftId] = _rewardPerTokenStored;
    }
  }

  function rewardsLeft() external view returns (uint256) {
    if (block.timestamp >= _rewardEndTimestamp) return 0;
    uint256 _remaining = _rewardEndTimestamp - block.timestamp;
    return _remaining * _rewardRate;
  }

  /**
   * @dev Changes the reward rate for the gauge.
   *
   * @param newRewardRate The new reward rate to set.
   */
  function setRewardRate(uint256 newRewardRate) external onlyOwner {
    if (newRewardRate == 0) revert Gauge__InvalidRewardRate();

    // Verify that the contract has enough balance for the newRewardRate
    if (
      IERC20(_rewardToken).balanceOf(address(this)) <
      newRewardRate * (_rewardEndTimestamp - block.timestamp)
    ) revert Gauge__InvalidBalance();

    // Update rewards globally
    updateReward(0); // Update rewards globally
    _rewardRate = newRewardRate;
  }

  /**
   * @dev Returns the current reward rate.
   *
   * @return The current reward rate.
   */
  function getRewardRate() external view returns (uint256) {
    return _rewardRate;
  }

  /**
   * @dev Returns the reward end timestamp.
   *
   * @return The reward end timestamp.
   */
  function getRewardEndTimestamp() external view returns (uint256) {
    return _rewardEndTimestamp;
  }

  /**
   * @dev Returns the reward start timestamp.
   *
   * @return The reward start timestamp.
   */
  function getRewardStartTimestamp() external view returns (uint256) {
    return _rewardStartTimestamp;
  }

  /**
   * @dev Returns the stored reward per token.
   *
   * @return The stored reward per token.
   */
  function getRewardPerTokenStored() external view returns (uint256) {
    return _rewardPerTokenStored;
  }

  /**
   * @dev Returns the last update time.
   *
   * @return The last update time.
   */
  function getLastUpdateTime() external view returns (uint256) {
    return _lastUpdateTime;
  }

  /**
   * @dev Returns the staking token address.
   *
   * @return The staking token address.
   */
  function getStakingToken() external view returns (IERC20) {
    return _stakingToken;
  }

  /**
   * @dev Returns the reward token address.
   *
   * @return The reward token address.
   */
  function getRewardToken() external view returns (IERC20) {
    return _rewardToken;
  }

  /**
   * @notice Returns the total locked amount
   * @return The total locked amount
   */
  function getTotalLocked() external view returns (uint256) {
    return _totalLocked;
  }

  /**
   * @notice Returns the lock for a given NFT ID
   * @param nftId The ID of the NFT
   * @return The lock
   */
  function getLock(uint256 nftId) external view returns (Lock memory) {
    if (nftId < 1 || nftId >= _nftIdCounter) revert Gauge__InvalidNFT();
    return _locksPerNft[nftId];
  }

  /**
   * @notice Returns the locks for a given address
   * @param user The address to get the locks for
   * @return The locks
   */
  function getLocksForAddress(address user) external view returns (Lock[] memory) {
    Lock[] memory locks = new Lock[](balanceOf(user));
    for (uint256 i = 0; i < balanceOf(user); i++) {
      uint256 nftId = tokenOfOwnerByIndex(user, i);
      locks[i] = _locksPerNft[nftId];
    }
    return locks;
  }

  /**
   * @notice Returns the total number of locks for a given address
   * @param user The address to get the total number of locks for
   * @return The total number of locks
   */
  function getTotalLocksForAddress(address user) external view returns (uint256) {
    return balanceOf(user);
  }
  /**
   * @notice Returns the total number of locks
   * @return The total number of locks
   */
  function getTotalLocks() external view returns (uint256) {
    return totalSupply();
  }
  /**
   * @notice Returns the boosting factor for a given lock duration
   * @param lockDuration The duration of the lock
   * @return The boosting factor
   */
  function getBoostingFactor(uint256 lockDuration) public pure returns (uint256, uint256) {
    // 0x 1.0x Boost
    if (lockDuration == 0) return (0, ONE_HUNDRED_PERCENT );
    // 0 - 1 month 1.1x Boost
    if (lockDuration >= 0 && lockDuration <= ONE_MONTH) return (ONE_MONTH, ONE_TEN_PERCENT);
    // 1 - 3 months 1.2x Boost
    if (lockDuration > ONE_MONTH && lockDuration <= THREE_MONTHS)
      return (THREE_MONTHS, ONE_TWENTY_PERCENT);
    // 3 - 6 months 1.3x Boost
    if (lockDuration > THREE_MONTHS && lockDuration <= SIX_MONTHS)
      return (SIX_MONTHS, ONE_THIRTY_PERCENT);
    // 6 - 12 months 1.4x Boost
    if (lockDuration > THREE_MONTHS && lockDuration <= TWELVE_MONTHS)
      return (TWELVE_MONTHS, ONE_FOURTY_PERCENT);
    // 12 - 24 months 1.5x Boost
    if (lockDuration > TWELVE_MONTHS && lockDuration <= TWENTY_FOUR_MONTHS)
      return (TWENTY_FOUR_MONTHS, ONE_FIFTY_PERCENT);
    // 24 - 48 months 1.6x Boost
    if (lockDuration > TWENTY_FOUR_MONTHS && lockDuration <= FOURTY_EIGHT_MONTHS)
      return (FOURTY_EIGHT_MONTHS, ONE_SIXTY_PERCENT);
    // Invalid duration
    revert Gauge__InvalidDuration();
  }

  /**
   * @notice Internal function to convert uint256 to string
   * @param _i The uint256 to convert
   * @return The string representation of the uint256
   */
  function _uint2str(uint256 _i) internal pure returns (string memory) {
    if (_i == 0) {
      return "0";
    }
    uint256 j = _i;
    uint256 len;
    while (j != 0) {
      len++;
      j /= 10;
    }
    bytes memory bstr = new bytes(len);
    uint256 k = len;
    while (_i != 0) {
      bstr[--k] = bytes1(uint8(48 + (_i % 10)));
      _i /= 10;
    }
    return string(bstr);
  }
  /**
   * @notice Returns the URI of the NFT
   * @param tokenId The ID of the NFT
   * @return The URI of the NFT
   */
  function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
    Lock storage lock = _locksPerNft[tokenId];
    return
      string(
        abi.encodePacked(
          "{",
          '"amount": ',
          _uint2str(lock.amount),
          ",",
          '"shares": ',
          _uint2str(lock.shares),
          ",",
          '"boostingFactor": ',
          _uint2str(lock.boostingFactor),
          ",",
          '"unlockTime": ',
          _uint2str(lock.unlockTime),
          "}"
        )
      );
  }
}
