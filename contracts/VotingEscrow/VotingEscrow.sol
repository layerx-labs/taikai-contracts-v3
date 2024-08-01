// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IVeTokenSettings } from "./interfaces/IVeTokenSettings.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IVeToken } from "./interfaces/IVeToken.sol";

/// @title VeToken
/// @notice This contract represents a token with locking functionality.
/// An ERC20 token that allocates users a virtual balance depending
/// on the amount of tokens locked and their remaining lock duration. The
/// virtual balance increases linearly with the remaining lock duration.
/// @dev Builds on Curve Finance's original VotingEscrow implementation
/// (see https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy)
/// and mStable's Solidity translation thereof
/// (see https://github.com/mstable/mStable-contracts/blob/master/contracts/governance/IncentivisedVotingLockup.sol)
/// Usage of this contract is not safe with all tokens, specifically:
/// - Contract does not support tokens with maxSupply>2^128-10^[decimals]
/// - Contract does not support fee-on-transfer tokens
/// - Contract may be unsafe for tokens with decimals<6
contract VeToken is IVeToken, Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  // Shared Events
  event Deposit(
    address indexed provider,
    uint256 value,
    uint256 locktime,
    ActionType indexed action,
    uint256 ts
  );
  event Withdraw(address indexed provider, uint256 value, uint256 ts);

  IERC20 private immutable _token;

  /// @notice Total amount of tokens locked in the contract
  uint256 private _totalLocked;
  uint256 private constant WEEK = 1 weeks;
  uint256 private constant MULTIPLIER = 1e18;

  // Lock state
  uint256 private _globalEpoch;
  Point[1000000000000000000] private _pointHistory; // 1e9 * userPointHistory-length, so sufficient for 1e9 users
  mapping(address => Point[1000000000]) private _userPointHistory;
  mapping(address => uint256) private _userPointEpoch;
  mapping(uint256 => int128) private _slopeChanges;
  mapping(address => LockedBalance) private _locked;

  // Voting token
  string private _name;
  string private _symbol;
  uint8 private immutable _decimals;
  string private _version;
  address private immutable _settings;

  // Structs
  struct Point {
    int128 bias;
    int128 slope;
    uint256 ts;
    uint256 blk;
  }
  struct LockedBalance {
    int128 amount;
    uint256 end;
    uint256 start;
  }

  // Miscellaneous
  enum ActionType {
    DEPOSIT,
    INCREASE_LOCK_AMOUNT
  }

  /**
        @notice Constructor to initialize the VeToken contract.
        @param token_ The address of the token (Eg.: TKAI address).
        @param name_ The name for this VeToken.
        @param symbol_ The symbol for this VeToken.
        @param version_ The version for this VeToken.
        @param settings_ The address for the settings contract.
    */
  constructor(
    address token_,
    string memory name_,
    string memory symbol_,
    string memory version_,
    address settings_
  ) Ownable() ReentrancyGuard() {
    require(token_ != address(0), "token_ cannot be zero address");
    _token = IERC20(token_);
    _pointHistory[0] = Point({
      bias: int128(0),
      slope: int128(0),
      ts: block.timestamp,
      blk: block.number
    });

    _decimals = IERC20Metadata(token_).decimals();
    require(_decimals <= 18 && _decimals >= 6, "Decimals should be between 6 to 18");

    _name = name_;
    _symbol = symbol_;
    _version = version_;
    _settings = settings_;
  }

  // GETTERS
  /// @inheritdoc IVeToken
  function name() external view override returns (string memory) {
    return _name;
  }

  /// @inheritdoc IVeToken
  function symbol() external view override returns (string memory) {
    return _symbol;
  }

  /// @inheritdoc IVeToken
  function decimals() external view override returns (uint8) {
    return _decimals;
  }

  /// @inheritdoc IVeToken
  function version() external view override returns (string memory) {
    return _version;
  }

  /// @inheritdoc IVeToken
  function settings() external view override returns (address) {
    return _settings;
  }

  /// @inheritdoc IVeToken
  function token() external view override returns (address) {
    return address(_token);
  }

  /// @inheritdoc IVeToken
  function totalLocked() external view override returns (uint256) {
    return _totalLocked;
  }

  /// @notice Records a checkpoint of both individual and global slope
  /// @param addr_ The address of the lock owner, or address(0) for only global
  /// @param oldLocked_ Old amount that user had locked, or null for global
  /// @param newLocked_ New amount that user has locked, or null for global
  function _checkpoint(
    address addr_,
    LockedBalance memory oldLocked_,
    LockedBalance memory newLocked_
  ) internal {
    Point memory userOldPoint;
    Point memory userNewPoint;
    int128 oldSlopeDelta = 0;
    int128 newSlopeDelta = 0;
    uint256 epoch = _globalEpoch;
    if (addr_ != address(0)) {
      // Calculate slopes and biases
      // Kept at zero when they have to
      // Casting in the next blocks is safe given that MAXTIME is a small
      // positive number and we check for _oldLocked.end>block.timestamp
      // and newLocked_.end>block.timestamp
      if (oldLocked_.end > block.timestamp && oldLocked_.amount > 0) {
        userOldPoint.slope = oldLocked_.amount / IVeTokenSettings(_settings).locktime();
        userOldPoint.bias = userOldPoint.slope * int128(int256(block.timestamp - oldLocked_.start));
      }
      if (newLocked_.end > block.timestamp && newLocked_.amount > 0) {
        userNewPoint.slope = newLocked_.amount / IVeTokenSettings(_settings).locktime();

        userNewPoint.bias = userNewPoint.slope * int128(int256(block.timestamp - newLocked_.start));
      }

      // Moved from bottom final if statement to resolve stack too deep err
      // start {
      // Now handle user history
      uint256 uEpoch = _userPointEpoch[addr_];

      _userPointEpoch[addr_] = uEpoch + 1;
      userNewPoint.ts = block.timestamp;
      userNewPoint.blk = block.number;
      _userPointHistory[addr_][uEpoch + 1] = userNewPoint;

      // } end

      // Read values of scheduled changes in the slope
      // oldLocked.end can be in the past and in the future
      // newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
      oldSlopeDelta = _slopeChanges[oldLocked_.end];
      if (newLocked_.end != 0) {
        if (newLocked_.end == oldLocked_.end) {
          newSlopeDelta = oldSlopeDelta;
        } else {
          newSlopeDelta = _slopeChanges[newLocked_.end];
        }
      }
    }

    Point memory lastPoint = Point({ bias: 0, slope: 0, ts: block.timestamp, blk: block.number });
    if (epoch > 0) {
      lastPoint = _pointHistory[epoch];
    }
    uint256 lastCheckpoint = lastPoint.ts;

    // initialLastPoint is used for extrapolation to calculate block number
    // (approximately, for *At methods) and save them
    // as we cannot figure that out exactly from inside the contract
    Point memory initialLastPoint = Point({
      bias: 0,
      slope: 0,
      ts: lastPoint.ts,
      blk: lastPoint.blk
    });
    uint256 blockSlope = 0; // dblock/dt
    if (block.timestamp > lastPoint.ts) {
      blockSlope = (MULTIPLIER * (block.number - lastPoint.blk)) / (block.timestamp - lastPoint.ts);
    }
    // If last point is already recorded in this block, slope=0
    // But that's ok b/c we know the block in such case

    // Go over weeks to fill history and calculate what the current point is
    uint256 iterativeTime = _floorToWeek(lastCheckpoint);
    for (uint256 i; i < 255; ) {
      // Hopefully it won't happen that this won't get used in 5 years!
      // If it does, users will be able to withdraw but vote weight will be broken
      iterativeTime = iterativeTime + WEEK;
      int128 dSlope = 0;
      if (iterativeTime > block.timestamp) {
        iterativeTime = block.timestamp;
      } else {
        dSlope = _slopeChanges[iterativeTime];
      }
      int128 biasDelta = lastPoint.slope * int128(int256((iterativeTime - lastCheckpoint)));
      lastPoint.bias = lastPoint.bias + biasDelta;
      lastPoint.slope = lastPoint.slope + dSlope;
      // This can happen
      if (lastPoint.bias < 0) {
        lastPoint.bias = 0;
      }
      // This cannot happen - just in case
      if (lastPoint.slope < 0) {
        lastPoint.slope = 0;
      }
      lastCheckpoint = iterativeTime;
      lastPoint.ts = iterativeTime;
      lastPoint.blk =
        initialLastPoint.blk +
        (blockSlope * (iterativeTime - initialLastPoint.ts)) /
        MULTIPLIER;

      // when epoch is incremented, we either push here or after slopes updated below
      epoch = epoch + 1;
      if (iterativeTime == block.timestamp) {
        lastPoint.blk = block.number;
        break;
      } else {
        _pointHistory[epoch] = lastPoint;
      }
      unchecked {
        ++i;
      }
    }

    _globalEpoch = epoch;
    // Now pointHistory is filled until t=now

    if (addr_ != address(0)) {
      // If last point was in this block, the slope change has been applied already
      // But in such case we have 0 slope(s)
      lastPoint.slope = lastPoint.slope + userNewPoint.slope - userOldPoint.slope;
      lastPoint.bias = lastPoint.bias + userNewPoint.bias - userOldPoint.bias;
      if (lastPoint.slope < 0) {
        lastPoint.slope = 0;
      }
      if (lastPoint.bias < 0) {
        lastPoint.bias = 0;
      }
    }

    // Record the changed point into history
    _pointHistory[epoch] = lastPoint;

    if (addr_ != address(0)) {
      // Schedule the slope changes (slope is going down)
      // We subtract new_user_slope from [new_locked.end]
      // and add old_user_slope to [old_locked.end]
      if (oldLocked_.end > block.timestamp) {
        // oldSlopeDelta was <something> - userOldPoint.slope, so we cancel that
        oldSlopeDelta = oldSlopeDelta + userOldPoint.slope;
        if (newLocked_.end == oldLocked_.end) {
          oldSlopeDelta = oldSlopeDelta - userNewPoint.slope; // It was a new deposit, not extension
        }
        _slopeChanges[oldLocked_.end] = oldSlopeDelta;
      }
      if (newLocked_.end > block.timestamp) {
        if (newLocked_.end > oldLocked_.end) {
          newSlopeDelta = newSlopeDelta - userNewPoint.slope; // old slope disappeared at this point
          _slopeChanges[newLocked_.end] = newSlopeDelta;
        }
        // else: we recorded it already in oldSlopeDelta
      }
    }
  }

  /// @notice Locks more tokens in an existing lock
  /// @param value_ Amount of tokens to add to the lock
  /// @dev Does not update the lock's expiration
  /// Does record a new checkpoint for the lock
  /// `value_` is (unsafely) downcasted from `uint256` to `int128` assuming
  /// that the max value is never reached in practice
  function _increaseAmount(uint256 value_) internal {
    LockedBalance memory locked = _locked[msg.sender];
    // Validate inputs
    // Update _totalLocked of token deposited
    _totalLocked = _totalLocked + value_;
    // Update lock
    uint256 unlockTime = locked.end;
    ActionType action = ActionType.INCREASE_LOCK_AMOUNT;
    LockedBalance memory newLocked;
    locked.amount = locked.amount + int128(int256(value_));
    _locked[msg.sender] = locked;

    newLocked = _copyLock(locked);
    _locked[msg.sender] = newLocked;
    _checkpoint(msg.sender, locked, newLocked);
    // Checkpoint only for delegatee
    // Deposit _locked tokens
    _token.safeTransferFrom(msg.sender, address(this), value_);
    emit Deposit(msg.sender, value_, unlockTime, action, block.timestamp);
  }

  // Creates a copy of a lock
  function _copyLock(LockedBalance memory locked_) internal pure returns (LockedBalance memory) {
    return LockedBalance({ amount: locked_.amount, end: locked_.end, start: locked_.start });
  }

  // Floors a timestamp to the nearest weekly increment
  function _floorToWeek(uint256 t_) internal pure returns (uint256) {
    return (t_ / WEEK) * WEEK;
  }

  // Calculate total supply of voting power at a given time t_
  // point_ is the most recent point before time t_
  // t_ is the time at which to calculate supply
  function _supplyAt(Point memory point_, uint256 t_) internal view returns (uint256) {
    Point memory lastPoint = point_;
    // Floor the timestamp to weekly interval
    uint256 iterativeTime = _floorToWeek(lastPoint.ts);
    // Iterate through all weeks between point_ & t_ to account for slope changes
    for (uint256 i; i < 255; ) {
      iterativeTime = iterativeTime + WEEK;
      int128 dSlope = 0;
      // If week end is after timestamp, then truncate & leave dSlope to 0
      if (iterativeTime > t_) {
        iterativeTime = t_;
      }
      // else get most recent slope change
      else {
        dSlope = _slopeChanges[iterativeTime];
      }

      // Casting is safe given that lastPoint.ts < iterativeTime and
      // iteration goes over 255 weeks max
      lastPoint.bias =
        lastPoint.bias +
        (lastPoint.slope * int128(int256(iterativeTime - lastPoint.ts)));
      if (iterativeTime == t_) {
        break;
      }
      lastPoint.slope = lastPoint.slope + dSlope;
      lastPoint.ts = iterativeTime;

      unchecked {
        ++i;
      }
    }

    return uint256(uint128(lastPoint.bias));
  }

  /// @inheritdoc IVeToken
  function deposit(uint256 value_) external override nonReentrant {
    require(msg.sender == tx.origin, "No contracts allowed");
    require(value_ > 0, "Value should be greater than 0");
    LockedBalance memory locked = _locked[msg.sender];

    if (locked.amount > 0) {
      require(locked.end > block.timestamp, "Cannot add to expired lock. Withdraw");
      _increaseAmount(value_);
    } else {
      uint256 unlock_time = block.timestamp +
        uint256(int256(IVeTokenSettings(_settings).locktime()));
      // Update total supply of token deposited
      _totalLocked = _totalLocked + value_;
      // Update lock and voting power (checkpoint)
      // Casting in the next block is safe given that we check for value_>0 and the
      // totalSupply of tokens is generally significantly lower than the int128.max
      // value (considering the max precision of 18 decimals enforced in the constructor)
      locked.amount = locked.amount + int128(int256(value_));
      locked.end = unlock_time;
      locked.start = block.timestamp;
      _locked[msg.sender] = locked;
      _checkpoint(msg.sender, LockedBalance(0, 0, 0), locked);
      // Deposit _locked tokens
      _token.safeTransferFrom(msg.sender, address(this), value_);
      emit Deposit(msg.sender, value_, unlock_time, ActionType.DEPOSIT, block.timestamp);
    }
  }

  /// @inheritdoc IVeToken
  function lockedEnd(address addr_) external view override returns (uint256) {
    return _locked[addr_].end;
  }

  /// @inheritdoc IVeToken
  function withdraw(uint256 amount_) external override nonReentrant {
    LockedBalance memory locked = _locked[msg.sender];
    // Validate inputs
    require(locked.amount > 0, "No Deposits");
    require(uint256(uint128(locked.amount)) >= amount_, "Insufficient balance");

    _totalLocked = _totalLocked - amount_;
    // Update lock
    LockedBalance memory newLocked = _copyLock(locked);
    newLocked.amount = newLocked.amount - int128(uint128(amount_));
    if (newLocked.amount == 0) {
      newLocked.end = 0;
    }

    _locked[msg.sender] = newLocked;

    // oldLocked can have either expired <= timestamp or zero end
    // currentLock has only 0 end
    // Both can have >= 0 amount
    _checkpoint(msg.sender, locked, newLocked);
    // Send back deposited tokens
    _token.safeTransfer(msg.sender, amount_);
    emit Withdraw(msg.sender, amount_, block.timestamp);
  }

  /// @inheritdoc IVeToken
  function balanceOf(address addr_) external view override returns (uint256) {
    uint256 epoch = _userPointEpoch[addr_];
    if (epoch == 0 || _locked[addr_].end == 0) {
      return 0;
    }

    // Casting is safe given that checkpoints are recorded in the past
    // and are more frequent than every int128.max seconds
    Point memory lastPoint = _userPointHistory[addr_][epoch];
    if (_locked[addr_].end > block.timestamp) {
      // When the lock has not expired yet
      lastPoint.bias += lastPoint.slope * int128(uint128(block.timestamp - _locked[addr_].start));
    } else {
      // When the lock has expired
      lastPoint.bias += lastPoint.slope * int128(uint128(_locked[addr_].end - lastPoint.ts));
    }

    return uint256(int256(lastPoint.bias));
  }

  /// @inheritdoc IVeToken
  function totalSupply() external view override returns (uint256) {
    uint256 epoch = _globalEpoch;
    Point memory lastPoint = _pointHistory[epoch];
    return _supplyAt(lastPoint, block.timestamp);
  }

  function allowance(address, address) external pure override returns (uint256) {
    revert();
  }
  function transfer(address, uint256) external pure override returns (bool) {
    revert();
  }
  function approve(address, uint256) external pure override returns (bool) {
    revert();
  }
  function transferFrom(address, address, uint256) external pure override returns (bool) {
    revert();
  }
}
