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

/**
 * @title Gauge contract

 * @author Helder Vasconcelos <helder@layex.xyz>
 * @notice Gauge contract for distributing rewards to ERC20 Staker
 *
 * it accepts deposits and withdrawals of staking tokens (ERC20) and distributes rewards to the stakers (ERC20)
 * When the user deposits the tokens receives Gauge tokens (ERC20)
 * When the user withdraws the tokens the Gauge tokens are burned and the user receives the staking tokens
 * The rewards are distributed based on the Gauge tokens balance
 */
contract ERC20Gauge is ERC721URIStorage, Ownable {

  event Deposit(address indexed from, address indexed receiver, uint256 amount, uint256 time);
  event Withdraw(address indexed owner, address indexed receiver, uint256 amount);

  error Gauge__InvalidBalance();
  error Gauge__InvalidToken();
  error Gauge__InvalidRewardRate();
  error Gauge__ZeroAmount();
  error Gauge__InvalidDuration();
  error Gauge__InvalidNFT();
  error Gauge__NotOwner();
  error Gauge__NotUnlocked();

  using SafeERC20 for IERC20;

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
  uint256 constant TWO_MONTHS = 2 * ONE_MONTH;
  uint256 constant THREE_MONTHS = 3 * ONE_MONTH;
  uint256 constant FOUR_MONTHS = 4 * ONE_MONTH;
  uint256 constant FIVE_MONTHS = 5 * ONE_MONTH;
  uint256 constant SIX_MONTHS = 6 * ONE_MONTH;
  uint256 constant FOURTY_EIGHT_MONTHS = 48 * ONE_MONTH;

  uint256 internal constant PRECISION = 10 ** 18;
  uint256 internal constant BOOST_PRECISION = 100;

  /// @notice Address of the pool LP token which is deposited (staked) for rewards
  IERC20 private immutable _stakingToken;

  /// @notice Address of the reward token
  IERC20 private immutable _rewardToken;

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

  /// @notice Timestamp at which the reward rate starts
  uint256 private _rewardStartTimestamp;

  /// @notice Timestamp at which the reward rate ends
  uint256 private _rewardEndTimestamp;

  /// @notice Mapping of user address to their lock details
  uint256 private _totalShares;


  /// @notice Mapping of NFT ID to lock details
  mapping(uint256 => Lock) public _locksPerNft;

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
    if (_stakingToken == IERC20(address(0)) || _rewardToken == IERC20(address(0))) revert Gauge__InvalidToken();
    //Validate reward duration
    if (duration == 0) revert Gauge__InvalidDuration();
    // Validate that we have enough balance to start the reward rate
    if (balanceOf(address(this)) < initialRewardRate * duration) revert Gauge__InvalidBalance();
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
  function deposit(address receiver, uint256 amount, uint256 time) external returns (uint256 nftId) {
    if (amount == 0) revert Gauge__ZeroAmount();

    uint256 tokenId = _nftIdCounter; // Get the current token ID
    updateReward(tokenId);
    // Mint the amount of tokens to the sender
    nftId = _mintNFT(receiver, amount, time);

    // Transfer the amount of tokens from the sender to the gauge
    IERC20(_stakingToken).safeTransferFrom(msg.sender, address(this), amount);

    emit Deposit(msg.sender, receiver, amount, time);
  }

  function _mintNFT(address to, uint256 amount, uint256 time) internal returns (uint256) {
    uint256 tokenId = _nftIdCounter; // Get the current token ID
    _mint(to, tokenId); // Mint the NFT

    (uint256 fixedDuration, uint256 boostingFactor) = getBoostingFactor(time);

    uint256 shares = (amount * boostingFactor) / PRECISION;

    Lock storage lock = _locksPerNft[tokenId];
    lock.amount = amount;
    lock.shares = shares;
    lock.boostingFactor = boostingFactor;
    lock.unlockTime = block.timestamp + fixedDuration;

    _setTokenURI(tokenId, string(abi.encodePacked(
      "{",
      "\"amount\": ", uint2str(lock.amount), ",",
      "\"shares\": ", uint2str(lock.shares), ",",
      "\"boostingFactor\": ", uint2str(lock.boostingFactor), ",",
      "\"unlockTime\": ", uint2str(lock.unlockTime),
      "}"
    )));
    _totalShares += shares;

    // Set the UR
    _nftIdCounter++; // Increment the token ID counter
    return tokenId; // Return the token ID
  }

  // Helper function to convert uint256 to string
  function uint2str(uint256 _i) internal pure returns (string memory _uintAsString) {
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
      bstr[--k] = bytes1(uint8(48 + _i % 10));
      _i /= 10;
    }
    return string(bstr);
  }

  /**
   * @dev Withdraws an amount of tokens from the gauge.
   *
   * @param nftId The NFT ID of the lock to withdraw.
   */
  function withdraw(uint256 nftId, address receiver) external {
    // Validate the token ID
    if (nftId < 1 || nftId >= _nftIdCounter) revert Gauge__InvalidNFT();
    // Validate the owner of the token
    if (msg.sender != ownerOf(nftId)) revert Gauge__NotOwner();
    // Validate the unlock time
    if (_locksPerNft[nftId].unlockTime > block.timestamp) revert Gauge__NotUnlocked();

    updateReward(nftId);

    _totalShares -= _locksPerNft[nftId].shares;

    uint256 amount = _locksPerNft[nftId].amount;

    delete _locksPerNft[nftId];

    _burn(nftId);
    // Transfer the amount of tokens from the gauge to the sender
    IERC20(_stakingToken).safeTransfer(receiver, amount);

    emit Withdraw(msg.sender,  receiver, amount);
  }

  /**
   * @dev Claims the earned rewards for the sender.
   */

  function claimRewards(uint256 nftId) external {
    updateReward(nftId);
    address account = ownerOf(nftId);
    uint256 reward = _rewards[nftId];
    if (reward > 0) {
      _rewards[nftId] = 0;
      _rewardToken.safeTransfer(account, reward);
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

  function getPosition(uint256 nftId) external view returns (Lock memory) {
    return _locksPerNft[nftId];
  }

  function getTotalLocked() external view returns (uint256) {
      return IERC20(_stakingToken).balanceOf(address(this));
  }


  function getBoostingFactor(uint256 lockDuration) public pure returns (uint256, uint256) {
    if (lockDuration == 0)
        return (ONE_HUNDRED_PERCENT, 0); // 1.0
    if (lockDuration >= 0 && lockDuration < ONE_MONTH)
        return (ONE_MONTH, ONE_TEN_PERCENT); // 1.1
    if (lockDuration >= ONE_MONTH && lockDuration < TWO_MONTHS)
      return (TWO_MONTHS, ONE_TWENTY_PERCENT); // 1.2
    if (lockDuration >= TWO_MONTHS && lockDuration < THREE_MONTHS)
      return (THREE_MONTHS, ONE_THIRTY_PERCENT ); // 1.4
    if (lockDuration >= THREE_MONTHS && lockDuration < FOUR_MONTHS)
      return (FOUR_MONTHS, ONE_FOURTY_PERCENT ); // 1.5
    if (lockDuration >= FOUR_MONTHS && lockDuration < FIVE_MONTHS)
      return (FIVE_MONTHS, ONE_FIFTY_PERCENT ); // 1.5
    if (lockDuration >= FIVE_MONTHS && lockDuration < SIX_MONTHS)
      return (SIX_MONTHS, ONE_SIXTY_PERCENT ); // 1.6
    if (lockDuration == FOURTY_EIGHT_MONTHS)
      return (FOURTY_EIGHT_MONTHS, ONE_SEVENTY_PERCENT); // 1.7
    revert Gauge__InvalidDuration();
  }
}
