// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IVeToken } from "./interfaces/IVeToken.sol";

/// @title Voting Escrow Template
/// @notice Cooldown logic is added in the contract
/// @notice Make contract upgradeable
/// @notice This is a Solidity implementation of the CURVE's voting escrow.
/// @notice Votes have a weight depending on time, so that users are
///         committed to the future of (whatever they are voting for)
/// @dev Vote weight decays linearly over time. Lock time cannot be
///  more than `MAX_TIME` (4 years).

/**
# Voting escrow to have time-weighted votes
# w ^
# 1 +        /
#   |      /
#   |    /
#   |  /
#   |/
# 0 +--------+------> time
#       maxtime (4 years?)
*/
contract VeToken is IVeToken, Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  enum ActionType {
    DEPOSIT_FOR,
    CREATE_LOCK,
    INCREASE_AMOUNT,
    INCREASE_LOCK_TIME
  }

  error ZeroAddressNotAllowed();
  error DecimalValueOutOfRange();
  error InvalidDepositAmount();
  error BlockNumberTooHigh();
  error NonExistingLock();
  error LockExpired();
  error LockNotExpired();
  error WithdrawOldTokensFirst();
  error CannotLockInThePast();
  error LockingPeriodTooLong();
  error LockingPeriodTooShort();
  error CanOnlyIncreaseLockDuration();

  struct Point {
    int128 bias; // veToken value at this point
    int128 slope; // slope at this point
    uint256 ts; // timestamp of this point
    uint256 blk; // block number of this point
  }
  /* We cannot really do block numbers per se b/c slope is per time, not per block
   * and per block could be fairly bad b/c Ethereum changes blocktimes.
   * What we can do is to extrapolate ***At functions */

  struct LockedBalance {
    uint128 amount; // amount of Token locked for a user.
    uint256 end; // the expiry time of the deposit.
  }

  // veToken token related
  string private _name;
  string private _symbol;
  uint8 private immutable _decimals;
  string private _version;
  IERC20 private immutable _token;

  uint256 private constant WEEK = 1 weeks;
  uint256 private constant MAX_TIME = 4 * 365 days;
  uint256 private constant MIN_TIME = 1 * WEEK;
  uint256 private constant MULTIPLIER = 10 ** 18;
  int128 private constant I_YEAR = int128(uint128(365 days));

  /// @dev Mappings to store global point information
  uint256 private _epoch;
  uint256 private _totalTokenLocked;
  mapping(uint256 => Point) private _pointHistory; // epoch -> unsigned point
  mapping(uint256 => int128) private _slopeChanges; // time -> signed slope change

  /// @dev Mappings to store user deposit information
  mapping(address => LockedBalance) private _lockedBalances; // user Deposits
  mapping(address => mapping(uint256 => Point)) private _userPointHistory; // user -> point[userEpoch]
  mapping(address => uint256) private _userPointEpoch;

  event UserCheckpoint(
    ActionType indexed actionType,
    address indexed provider,
    uint256 value,
    uint256 indexed locktime
  );

  event GlobalCheckpoint(address caller, uint256 epoch);
  event Withdraw(address indexed provider, uint256 value, uint256 ts);
  event Supply(uint256 prevSupply, uint256 supply);

  /// @dev Constructor
  constructor(
    address token_,
    string memory name_,
    string memory symbol_,
    string memory version_
  ) Ownable() ReentrancyGuard() {
    if (token_ == address(0)) {
      revert ZeroAddressNotAllowed();
    }
    _token = IERC20(token_);
    _decimals = IERC20Metadata(token_).decimals();
    if (_decimals > 18) {
      revert DecimalValueOutOfRange();
    }
    _name = name_;
    _symbol = symbol_;
    _version = version_;
    _pointHistory[0] = Point({
      bias: int128(0),
      slope: int128(0),
      ts: block.timestamp,
      blk: block.number
    });
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
  function totalLocked() external view override returns (uint256) {
    return _totalTokenLocked;
  }

  /// @inheritdoc IVeToken
  function getEpoch() external view override returns (uint256) {
    return _epoch;
  }

  /// @inheritdoc IVeToken
  function token() external view override returns (IERC20) {
    return _token;
  }

  /// @inheritdoc IVeToken
  function getLastUserSlope(address addr_) external view override returns (int128) {
    uint256 uEpoch = _userPointEpoch[addr_];
    if (uEpoch == 0) {
      return 0;
    }
    return _userPointHistory[addr_][uEpoch].slope;
  }

  /// @inheritdoc IVeToken
  function getUserPointHistoryTS(
    address addr_,
    uint256 idx
  ) external view override returns (uint256) {
    return _userPointHistory[addr_][idx].ts;
  }

  /// @inheritdoc IVeToken
  function lockedEnd(address addr_) external view override returns (uint256) {
    return _lockedBalances[addr_].end;
  }

  /// @inheritdoc IVeToken
  function lockedBalance(address addr_) external view override returns (uint256) {
    return _lockedBalances[addr_].amount;
  }

  /// @inheritdoc IVeToken
  function totalSupplyAt(uint256 blockNumber_) external view override returns (uint256) {
    if (blockNumber_ > block.number) {
      revert BlockNumberTooHigh();
    }
    uint256 epoch = _epoch;
    uint256 targetEpoch = _findBlockEpoch(blockNumber_, epoch);

    Point memory point0 = _pointHistory[targetEpoch];
    uint256 dt = 0;

    if (targetEpoch < epoch) {
      Point memory point1 = _pointHistory[targetEpoch + 1];
      dt = ((blockNumber_ - point0.blk) * (point1.ts - point0.ts)) / (point1.blk - point0.blk);
    } else {
      if (point0.blk != block.number) {
        dt =
          ((blockNumber_ - point0.blk) * (block.timestamp - point0.ts)) /
          (block.number - point0.blk);
      }
    }
    // Now dt contains info on how far we are beyond point0
    return _supplyAt(point0, point0.ts + dt);
  }

  /// @notice Get the voting power for a user at the specified timestamp
  /// @dev Adheres to ERC20 `balanceOf` interface for Aragon compatibility
  /// @param addr_ User wallet address
  /// @param ts_ Timestamp to get voting power at
  /// @return Voting power of user at timestamp
  function balanceOf(address addr_, uint256 ts_) public view returns (uint256) {
    uint256 epoch = _findUserTimestampEpoch(addr_, ts_);
    if (epoch == 0) {
      return 0;
    } else {
      Point memory lastPoint = _userPointHistory[addr_][epoch];
      lastPoint.bias -= lastPoint.slope * int128(int256(ts_) - int256(lastPoint.ts));
      if (lastPoint.bias < 0) {
        lastPoint.bias = 0;
      }

      return uint256(int256(lastPoint.bias));
    }
  }

  /// @inheritdoc IVeToken
  function balanceOf(address addr_) external view override returns (uint256) {
    return balanceOf(addr_, block.timestamp);
  }

  /// @inheritdoc IVeToken
  function balanceOfAt(
    address addr_,
    uint256 blockNumber_
  ) external view override returns (uint256) {
    uint256 min = 0;
    uint256 max = _userPointEpoch[addr_];

    // Find the approximate timestamp for the block number
    for (uint256 i = 0; i < 128; i++) {
      if (min >= max) {
        break;
      }
      uint256 mid = (min + max + 1) / 2;
      if (_userPointHistory[addr_][mid].blk <= blockNumber_) {
        min = mid;
      } else {
        max = mid - 1;
      }
    }

    // min is the userEpoch nearest to the block number
    Point memory uPoint = _userPointHistory[addr_][min];
    uint256 maxEpoch = _epoch;

    // blocktime using the global point history
    uint256 epoch = _findBlockEpoch(blockNumber_, maxEpoch);
    Point memory point0 = _pointHistory[epoch];
    uint256 dBlock = 0;
    uint256 dt = 0;

    if (epoch < maxEpoch) {
      Point memory point1 = _pointHistory[epoch + 1];
      dBlock = point1.blk - point0.blk;
      dt = point1.ts - point0.ts;
    } else {
      dBlock = blockNumber_ - point0.blk;
      dt = block.timestamp - point0.ts;
    }

    uint256 blockTime = point0.ts;
    if (dBlock != 0) {
      blockTime += (dt * (blockNumber_ - point0.blk)) / dBlock;
    }

    uPoint.bias -= uPoint.slope * int128(int256(blockTime) - int256(uPoint.ts));
    if (uPoint.bias < 0) {
      uPoint.bias = 0;
    }
    return uint256(int256(uPoint.bias));
  }

  /// @inheritdoc IVeToken
  function totalSupply() external view override returns (uint256) {
    return totalSupply(block.timestamp);
  }

  /// @notice Calculate total voting power at a given timestamp
  /// @return Total voting power at timestamp
  function totalSupply(uint256 ts_) public view returns (uint256) {
    uint256 epoch = _findGlobalTimestampEpoch(ts_);
    Point memory lastPoint = _pointHistory[epoch];
    return _supplyAt(lastPoint, ts_);
  }

  /// @inheritdoc IVeToken
  function checkpoint() external override {
    _updateGlobalPoint();
    emit GlobalCheckpoint(_msgSender(), _epoch);
  }

  /// @inheritdoc IVeToken
  function depositFor(address addr_, uint128 value_) external override nonReentrant {
    LockedBalance memory existingDeposit = _lockedBalances[addr_];
    if (value_ <= 0) {
      revert InvalidDepositAmount();
    }
    if (existingDeposit.amount <= 0) {
      revert NonExistingLock();
    }
    if (existingDeposit.end <= block.timestamp) {
      revert LockExpired();
    }

    _depositFor(addr_, value_, 0, existingDeposit, ActionType.DEPOSIT_FOR);
  }

  /// @inheritdoc IVeToken
  function createLock(uint128 value_, uint256 unlockTime_) external override nonReentrant {
    address account = _msgSender();
    LockedBalance memory existingDeposit = _lockedBalances[account];
    if (value_ <= 0) {
      revert InvalidDepositAmount();
    }
    if (existingDeposit.amount != 0) {
      revert WithdrawOldTokensFirst();
    }
    uint256 roundedUnlockTime = _validateLockTime(unlockTime_);

    _depositFor(account, value_, roundedUnlockTime, existingDeposit, ActionType.CREATE_LOCK);
  }

  /// @inheritdoc IVeToken
  function increaseAmount(uint128 value_) external override nonReentrant {
    address account = _msgSender();
    LockedBalance memory existingDeposit = _lockedBalances[account];

    if (value_ <= 0) {
      revert InvalidDepositAmount();
    }
    if (existingDeposit.amount <= 0) {
      revert NonExistingLock();
    }
    if (existingDeposit.end <= block.timestamp) {
      revert LockExpired();
    }

    _depositFor(account, value_, 0, existingDeposit, ActionType.INCREASE_AMOUNT);
  }

  /// @inheritdoc IVeToken
  function increaseUnlockTime(uint256 unlockTime_) external override {
    address account = _msgSender();
    LockedBalance memory existingDeposit = _lockedBalances[account];
    uint256 roundedUnlockTime = (unlockTime_ / WEEK) * WEEK; // Locktime is rounded down to weeks

    if (existingDeposit.amount <= 0) {
      revert NonExistingLock();
    }
    if (existingDeposit.end <= block.timestamp) {
      revert LockExpired();
    }
    if (roundedUnlockTime <= existingDeposit.end) {
      revert CanOnlyIncreaseLockDuration();
    }
    if (roundedUnlockTime > block.timestamp + MAX_TIME) {
      revert LockingPeriodTooLong();
    }

    _depositFor(account, 0, roundedUnlockTime, existingDeposit, ActionType.INCREASE_LOCK_TIME);
  }

  /// @inheritdoc IVeToken
  function withdraw() external override nonReentrant {
    address account = _msgSender();
    LockedBalance memory existingDeposit = _lockedBalances[account];
    if (existingDeposit.amount <= 0) {
      revert NonExistingLock();
    }
    if (existingDeposit.end > block.timestamp) {
      revert LockNotExpired();
    }

    uint128 value = existingDeposit.amount;

    LockedBalance memory oldDeposit = _lockedBalances[account];
    _lockedBalances[account] = LockedBalance(0, 0);
    uint256 prevSupply = _totalTokenLocked;
    _totalTokenLocked -= value;

    // oldDeposit can have either expired <= timestamp or 0 end
    // existingDeposit has 0 end
    // Both can have >= 0 amount
    _checkpoint(account, oldDeposit, LockedBalance(0, 0));

    IERC20(_token).safeTransfer(account, value);
    emit Withdraw(account, value, block.timestamp);
    emit Supply(prevSupply, _totalTokenLocked);
  }

  /// @notice Function to estimate the user deposit
  /// @param value_ Amount of Token to deposit
  /// @param expectedUnlockTime_ The expected unlock time
  function estimateDeposit(
    uint128 value_,
    uint256 expectedUnlockTime_
  )
    public
    view
    returns (
      int128 initialVeTokenBalance, // initial veToken balance
      int128 slope, // slope of the user's graph
      int128 bias, // bias of the user's graph
      uint256 actualUnlockTime, // actual rounded unlock time
      uint256 providedUnlockTime // expected unlock time
    )
  {
    actualUnlockTime = _validateLockTime(expectedUnlockTime_);

    int128 amt = int128(value_);
    slope = amt / I_YEAR;

    bias = slope * int128(int256(actualUnlockTime) - int256(block.timestamp));

    if (bias <= 0) {
      bias = 0;
    }

    return (bias, slope, bias, actualUnlockTime, expectedUnlockTime_);
  }

  /// @notice Record global and per-user data to checkpoint
  /// @param addr_ User wallet address. No user checkpoint if 0x0
  /// @param oldDeposit_ Previous locked balance / end lock time for the user
  /// @param newDeposit_ New locked balance / end lock time for the user
  function _checkpoint(
    address addr_,
    LockedBalance memory oldDeposit_,
    LockedBalance memory newDeposit_
  ) internal {
    Point memory uOld = Point(0, 0, 0, 0);
    Point memory uNew = Point(0, 0, 0, 0);
    int128 dSlopeOld = 0;
    int128 dSlopeNew = 0;

    // Calculate slopes and biases for oldDeposit_
    // Skipped in case of createLock
    if (oldDeposit_.amount > 0) {
      int128 amt = int128(oldDeposit_.amount);

      if (oldDeposit_.end > block.timestamp) {
        uOld.slope = amt / I_YEAR;

        uOld.bias = uOld.slope * int128(int256(oldDeposit_.end) - int256(block.timestamp));
      }
    }
    // Calculate slopes and biases for newDeposit_
    // Skipped in case of withdraw
    if ((newDeposit_.end > block.timestamp) && (newDeposit_.amount > 0)) {
      int128 amt = int128(newDeposit_.amount);

      if (newDeposit_.end > block.timestamp) {
        uNew.slope = amt / I_YEAR;
        uNew.bias = uNew.slope * int128(int256(newDeposit_.end) - int256(block.timestamp));
      }
    }

    // Read values of scheduled changes in the slope
    // oldDeposit_.end can be in the past and in the future
    // newDeposit_.end can ONLY be in the future, unless everything expired: than zeros
    dSlopeOld = _slopeChanges[oldDeposit_.end];
    if (newDeposit_.end != 0) {
      // if not "withdraw"
      dSlopeNew = _slopeChanges[newDeposit_.end];
    }

    // add all global checkpoints from last added global check point until now
    Point memory lastPoint = _updateGlobalPoint();
    // If last point was in this block, the slope change has been applied already
    // But in such case we have 0 slope(s)

    // update the last global checkpoint (now) with user action's consequences
    lastPoint.slope += (uNew.slope - uOld.slope); //TODO: why we can just add slopes up?
    lastPoint.bias += (uNew.bias - uOld.bias);

    if (lastPoint.slope < 0) {
      // it will never happen if everything works correctly
      lastPoint.slope = 0;
    }
    if (lastPoint.bias < 0) {
      // TODO: why it can be < 0?
      lastPoint.bias = 0;
    }
    _pointHistory[_epoch] = lastPoint; // Record the changed point into the global history by replacement

    // Schedule the slope changes (slope is going down)
    // We subtract new_user_slope from [new_locked.end]
    // and add old_user_slope to [old_locked.end]
    if (oldDeposit_.end > block.timestamp) {
      // old_dslope was <something> - u_old.slope, so we cancel that
      dSlopeOld += uOld.slope;
      if (newDeposit_.end == oldDeposit_.end) {
        // It was a new deposit, not extension
        dSlopeOld -= uNew.slope;
      }
      _slopeChanges[oldDeposit_.end] = dSlopeOld;
    }

    if (newDeposit_.end > block.timestamp) {
      if (newDeposit_.end > oldDeposit_.end) {
        dSlopeNew -= uNew.slope;
        // old slope disappeared at this point
        _slopeChanges[newDeposit_.end] = dSlopeNew;
      }
      // else: we recorded it already in old_dslopes̄
    }
    // Now handle user history
    uint256 userEpc = _userPointEpoch[addr_] + 1;
    _userPointEpoch[addr_] = userEpc;
    uNew.ts = block.timestamp;
    uNew.blk = block.number;
    _userPointHistory[addr_][userEpc] = uNew;
  }

  /// @notice Deposit and lock tokens for a user
  /// @param addr_ Address of the user
  /// @param value_ Amount of tokens to deposit
  /// @param unlockTime_ Time when the tokens will be unlocked
  /// @param oldDeposit_ Previous locked balance of the user / timestamp
  function _depositFor(
    address addr_,
    uint128 value_,
    uint256 unlockTime_,
    LockedBalance memory oldDeposit_,
    ActionType _type
  ) internal {
    LockedBalance memory newDeposit = _lockedBalances[addr_];
    uint256 prevSupply = _totalTokenLocked;

    _totalTokenLocked += value_;
    // Adding to existing lock, or if a lock is expired - creating a new one
    newDeposit.amount += value_;
    if (unlockTime_ != 0) {
      newDeposit.end = unlockTime_;
    }
    _lockedBalances[addr_] = newDeposit;

    /// Possibilities:
    // Both oldDeposit_.end could be current or expired (>/<block.timestamp)
    // value_ == 0 (extend lock) or value_ > 0 (add to lock or extend lock)
    // newDeposit.end > block.timestamp (always)
    _checkpoint(addr_, oldDeposit_, newDeposit);

    if (value_ != 0) {
      IERC20(_token).safeTransferFrom(_msgSender(), address(this), value_);
    }

    emit UserCheckpoint(_type, addr_, value_, newDeposit.end);
    emit Supply(prevSupply, _totalTokenLocked);
  }

  /// @notice Calculate total voting power at some point in the past
  /// @param point_ The point_ (bias/slope) to start search from
  /// @param ts_ Timestamp to calculate total voting power at
  /// @return Total voting power at timestamp
  function _supplyAt(Point memory point_, uint256 ts_) internal view returns (uint256) {
    Point memory lastPoint = point_;
    uint256 ti = (lastPoint.ts / WEEK) * WEEK;

    // Calculate the missing checkpoints
    for (uint256 i = 0; i < 255; i++) {
      ti += WEEK;
      int128 dSlope = 0;
      if (ti > ts_) {
        ti = ts_;
      } else {
        dSlope = _slopeChanges[ti];
      }
      lastPoint.bias -= lastPoint.slope * int128(int256(ti) - int256(lastPoint.ts));
      if (ti == ts_) {
        break;
      }
      lastPoint.slope += dSlope;
      lastPoint.ts = ti;
    }

    if (lastPoint.bias < 0) {
      lastPoint.bias = 0;
    }

    return uint256(int256(lastPoint.bias));
  }

  // ----------------------VIEW functions----------------------
  /// NOTE:The following ERC20/minime-compatible methods are not real balanceOf and supply!!
  /// They measure the weights for the purpose of voting, so they don't represent real coins.

  /// @notice Binary search to estimate timestamp for block number
  /// @param blockNumber_ Block number to estimate timestamp for
  /// @param maxEpoch_ Don't go beyond this epoch
  /// @return Estimated timestamp for block number
  function _findBlockEpoch(
    uint256 blockNumber_,
    uint256 maxEpoch_
  ) internal view returns (uint256) {
    uint256 min = 0;
    uint256 max = maxEpoch_;

    for (uint256 i = 0; i < 128; i++) {
      if (min >= max) {
        break;
      }
      uint256 mid = (min + max + 1) / 2;
      if (_pointHistory[mid].blk <= blockNumber_) {
        min = mid;
      } else {
        max = mid - 1;
      }
    }
    return min;
  }

  function _findUserTimestampEpoch(address addr_, uint256 ts_) internal view returns (uint256) {
    uint256 min = 0;
    uint256 max = _userPointEpoch[addr_];

    for (uint256 i = 0; i < 128; i++) {
      if (min >= max) {
        break;
      }
      uint256 mid = (min + max + 1) / 2;
      if (_userPointHistory[addr_][mid].ts <= ts_) {
        min = mid;
      } else {
        max = mid - 1;
      }
    }
    return min;
  }

  function _validateLockTime(uint256 locktime_) internal view returns (uint256) {
    uint256 roundedUnlockTime = (locktime_ / WEEK) * WEEK;

    if (roundedUnlockTime <= block.timestamp) {
      revert CannotLockInThePast();
    }
    if (roundedUnlockTime > block.timestamp + MAX_TIME) {
      revert LockingPeriodTooLong();
    }
    if (roundedUnlockTime < block.timestamp + MIN_TIME) {
      revert LockingPeriodTooShort();
    }
    return roundedUnlockTime;
  }

  function _findGlobalTimestampEpoch(uint256 ts_) internal view returns (uint256) {
    uint256 min = 0;
    uint256 max = _epoch;

    for (uint256 i = 0; i < 128; i++) {
      if (min >= max) {
        break;
      }
      uint256 mid = (min + max + 1) / 2;
      if (_pointHistory[mid].ts <= ts_) {
        min = mid;
      } else {
        max = mid - 1;
      }
    }
    return min;
  }

  /// @notice add checkpoints to pointHistory for every week from last added checkpoint until now
  /// @dev block number for each added checkpoint is estimated by their respective timestamp and the blockslope
  ///         where the blockslope is estimated by the last added time/block point and the current time/block point
  /// @dev pointHistory include all weekly global checkpoints and some additional in-week global checkpoints
  /// @return lastPoint by calling this function
  function _updateGlobalPoint() private returns (Point memory lastPoint) {
    uint256 epoch = _epoch;
    lastPoint = Point({
      bias: 0,
      slope: 0,
      ts: block.timestamp,
      blk: block.number //TODO: arbi-main-fork cannot test it
    });
    Point memory initialLastPoint = Point({
      bias: 0,
      slope: 0,
      ts: block.timestamp,
      blk: block.number //TODO: arbi-main-fork cannot test it
    });
    if (epoch > 0) {
      lastPoint = _pointHistory[epoch];
      initialLastPoint = _pointHistory[epoch];
    }
    uint256 lastCheckpoint = lastPoint.ts;

    // initialLastPoint is used for extrapolation to calculate block number
    // (approximately, for *At functions) and save them
    // as we cannot figure that out exactly from inside the contract
    uint256 blockSlope = 0; // dblock/dt
    if (block.timestamp > lastPoint.ts) {
      blockSlope = (MULTIPLIER * (block.number - lastPoint.blk)) / (block.timestamp - lastPoint.ts);
    }
    // If last point is already recorded in this block, blockSlope is zero
    // But that's ok b/c we know the block in such case.

    // Go over weeks to fill history and calculate what the current point is
    {
      uint256 ti = (lastCheckpoint / WEEK) * WEEK;
      for (uint256 i = 0; i < 255; i++) {
        // Hopefully it won't happen that this won't get used in 4 years!
        // If it does, users will be able to withdraw but vote weight will be broken

        ti += WEEK;
        int128 dslope = 0;
        if (ti > block.timestamp) {
          ti = block.timestamp;
        } else {
          dslope = _slopeChanges[ti]; //TODO: check if possible that dslope = zerovalue
        }
        // calculate the slope and bia of the new last point
        lastPoint.bias -= lastPoint.slope * int128(int256(ti) - int256(lastCheckpoint));
        lastPoint.slope += dslope;
        // check sanity
        if (lastPoint.bias < 0) {
          // This can happen //TODO: why it can happen?
          lastPoint.bias = 0;
        }
        if (lastPoint.slope < 0) {
          // This cannot happen, but just in case //TODO: why it cannot < 0?
          lastPoint.slope = 0;
        }

        lastCheckpoint = ti;
        lastPoint.ts = ti;
        lastPoint.blk =
          initialLastPoint.blk +
          (blockSlope * (ti - initialLastPoint.ts)) /
          MULTIPLIER;
        epoch += 1;
        if (ti == block.timestamp) {
          lastPoint.blk = block.number;
          _pointHistory[epoch] = lastPoint;
          break;
        }
        _pointHistory[epoch] = lastPoint;
      }
    }

    _epoch = epoch;
    return lastPoint;
  }
}
