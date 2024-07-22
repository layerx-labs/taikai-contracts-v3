// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.18;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IVeTokenSettings} from "./IVeTokenSettings.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IVeToken} from "./IVeToken.sol";

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

    // Shared global state
    IERC20 public immutable token;
    /// @notice Total amount of tokens locked in the contract
    uint256 public totalLocked;
    uint256 public constant WEEK = 1 weeks;
    uint256 public constant MULTIPLIER = 1e18;

    // Lock state
    uint256 public globalEpoch;
    Point[1000000000000000000] public pointHistory; // 1e9 * userPointHistory-length, so sufficient for 1e9 users
    mapping(address => Point[1000000000]) public userPointHistory;
    mapping(address => uint256) public userPointEpoch;
    mapping(uint256 => int128) public slopeChanges;
    mapping(address => LockedBalance) public locked;

    // Voting token
    string public name;
    string public symbol;
    uint256 public decimals;
    string public version;
    address public settings;

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
        @param _token The address of the token (Eg.: TKAI address).
        @param _name The name for this VeToken.
        @param _symbol The symbol for this VeToken.
        @param _version The version for this VeToken.
        @param _settings The address for the settings contract.
    */
    constructor(
        address _token,
        string memory _name,
        string memory _symbol,
        string memory _version,
        address _settings
    ) Ownable() ReentrancyGuard() {
        require(_token != address(0), "_token cannot be zero address");
        token = IERC20(_token);
        pointHistory[0] = Point({
            bias: int128(0),
            slope: int128(0),
            ts: block.timestamp,
            blk: block.number
        });

        decimals = IERC20Metadata(_token).decimals();
        require(
            decimals <= 18 && decimals >= 6,
            "Decimals should be between 6 to 18"
        );

        name = _name;
        symbol = _symbol;
        version = _version;
        settings = _settings;
    }

    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~~ ///
    ///       LOCK MANAGEMENT       ///
    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~~ ///

    /// @inheritdoc IVeToken
    function lockedEnd(address _addr) external view override returns (uint256) {
        return locked[_addr].end;
    }

    /// @notice Records a checkpoint of both individual and global slope
    /// @param _addr The address of the lock owner, or address(0) for only global
    /// @param _oldLocked Old amount that user had locked, or null for global
    /// @param _newLocked New amount that user has locked, or null for global
    function _checkpoint(
        address _addr,
        LockedBalance memory _oldLocked,
        LockedBalance memory _newLocked
    ) internal {
        Point memory userOldPoint;
        Point memory userNewPoint;
        int128 oldSlopeDelta = 0;
        int128 newSlopeDelta = 0;
        uint256 epoch = globalEpoch;
        if (_addr != address(0)) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            // Casting in the next blocks is safe given that MAXTIME is a small
            // positive number and we check for _oldLocked.end>block.timestamp
            // and _newLocked.end>block.timestamp
            if (_oldLocked.end > block.timestamp && _oldLocked.amount > 0) {
                userOldPoint.slope =
                    _oldLocked.amount /
                    IVeTokenSettings(settings).locktime();
                userOldPoint.bias =
                    userOldPoint.slope *
                    int128(int256(block.timestamp - _oldLocked.start));
            }
            if (_newLocked.end > block.timestamp && _newLocked.amount > 0) {
                userNewPoint.slope =
                    _newLocked.amount /
                    IVeTokenSettings(settings).locktime();

                userNewPoint.bias =
                    userNewPoint.slope *
                    int128(int256(block.timestamp - _newLocked.start));
            }

            // Moved from bottom final if statement to resolve stack too deep err
            // start {
            // Now handle user history
            uint256 uEpoch = userPointEpoch[_addr];

            userPointEpoch[_addr] = uEpoch + 1;
            userNewPoint.ts = block.timestamp;
            userNewPoint.blk = block.number;
            userPointHistory[_addr][uEpoch + 1] = userNewPoint;

            // } end

            // Read values of scheduled changes in the slope
            // oldLocked.end can be in the past and in the future
            // newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
            oldSlopeDelta = slopeChanges[_oldLocked.end];
            if (_newLocked.end != 0) {
                if (_newLocked.end == _oldLocked.end) {
                    newSlopeDelta = oldSlopeDelta;
                } else {
                    newSlopeDelta = slopeChanges[_newLocked.end];
                }
            }
        }

        Point memory lastPoint = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
        if (epoch > 0) {
            lastPoint = pointHistory[epoch];
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
            blockSlope =
                (MULTIPLIER * (block.number - lastPoint.blk)) /
                (block.timestamp - lastPoint.ts);
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
                dSlope = slopeChanges[iterativeTime];
            }
            int128 biasDelta = lastPoint.slope *
                int128(int256((iterativeTime - lastCheckpoint)));
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
                pointHistory[epoch] = lastPoint;
            }
            unchecked {
                ++i;
            }
        }

        globalEpoch = epoch;
        // Now pointHistory is filled until t=now

        if (_addr != address(0)) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            lastPoint.slope =
                lastPoint.slope +
                userNewPoint.slope -
                userOldPoint.slope;
            lastPoint.bias =
                lastPoint.bias +
                userNewPoint.bias -
                userOldPoint.bias;
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        // Record the changed point into history
        pointHistory[epoch] = lastPoint;

        if (_addr != address(0)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (_oldLocked.end > block.timestamp) {
                // oldSlopeDelta was <something> - userOldPoint.slope, so we cancel that
                oldSlopeDelta = oldSlopeDelta + userOldPoint.slope;
                if (_newLocked.end == _oldLocked.end) {
                    oldSlopeDelta = oldSlopeDelta - userNewPoint.slope; // It was a new deposit, not extension
                }
                slopeChanges[_oldLocked.end] = oldSlopeDelta;
            }
            if (_newLocked.end > block.timestamp) {
                if (_newLocked.end > _oldLocked.end) {
                    newSlopeDelta = newSlopeDelta - userNewPoint.slope; // old slope disappeared at this point
                    slopeChanges[_newLocked.end] = newSlopeDelta;
                }
                // else: we recorded it already in oldSlopeDelta
            }
        }
    }

    /// @inheritdoc IVeToken
    function deposit(uint256 _value) external override nonReentrant {
        require(msg.sender == tx.origin, "No contracts allowed");
        require(_value > 0, "Value should be greater than 0");
        LockedBalance memory locked_ = locked[msg.sender];

        if (locked_.amount > 0) {
            require(
                locked_.end > block.timestamp,
                "Cannot add to expired lock. Withdraw"
            );
            _increaseAmount(_value);
        } else {
            uint256 unlock_time = block.timestamp +
                uint256(int256(IVeTokenSettings(settings).locktime()));
            // Update total supply of token deposited
            totalLocked = totalLocked + _value;
            // Update lock and voting power (checkpoint)
            // Casting in the next block is safe given that we check for _value>0 and the
            // totalSupply of tokens is generally significantly lower than the int128.max
            // value (considering the max precision of 18 decimals enforced in the constructor)
            locked_.amount = locked_.amount + int128(int256(_value));
            locked_.end = unlock_time;
            locked_.start = block.timestamp;
            locked[msg.sender] = locked_;
            _checkpoint(msg.sender, LockedBalance(0, 0, 0), locked_);
            // Deposit locked tokens
            token.safeTransferFrom(msg.sender, address(this), _value);
            emit Deposit(
                msg.sender,
                _value,
                unlock_time,
                ActionType.DEPOSIT,
                block.timestamp
            );
        }
    }

    /// @notice Locks more tokens in an existing lock
    /// @param _value Amount of tokens to add to the lock
    /// @dev Does not update the lock's expiration
    /// Does record a new checkpoint for the lock
    /// `_value` is (unsafely) downcasted from `uint256` to `int128` assuming
    /// that the max value is never reached in practice
    function _increaseAmount(uint256 _value) internal {
        LockedBalance memory locked_ = locked[msg.sender];
        // Validate inputs
        // Update totalLocked of token deposited
        totalLocked = totalLocked + _value;
        // Update lock
        uint256 unlockTime = locked_.end;
        ActionType action = ActionType.INCREASE_LOCK_AMOUNT;
        LockedBalance memory newLocked;
        locked_.amount = locked_.amount + int128(int256(_value));
        locked[msg.sender] = locked_;

        newLocked = _copyLock(locked_);
        locked[msg.sender] = newLocked;
        _checkpoint(msg.sender, locked_, newLocked);
        // Checkpoint only for delegatee
        // Deposit locked tokens
        token.safeTransferFrom(msg.sender, address(this), _value);
        emit Deposit(msg.sender, _value, unlockTime, action, block.timestamp);
    }

    /// @inheritdoc IVeToken
    function withdraw(uint256 _amount) external override nonReentrant {
        LockedBalance memory locked_ = locked[msg.sender];
        // Validate inputs
        require(locked_.amount > 0, "No Deposits");
        require(
            uint256(uint128(locked_.amount)) >= _amount,
            "Insufficient balance"
        );

        totalLocked = totalLocked - _amount;
        // Update lock
        LockedBalance memory newLocked = _copyLock(locked_);
        newLocked.amount = newLocked.amount - int128(uint128(_amount));
        if (newLocked.amount == 0) {
            newLocked.end = 0;
        }

        locked[msg.sender] = newLocked;

        // oldLocked can have either expired <= timestamp or zero end
        // currentLock has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, locked_, newLocked);
        // Send back deposited tokens
        token.safeTransfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _amount, block.timestamp);
    }

    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~ ///
    ///            GETTERS         ///
    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~ ///

    // Creates a copy of a lock
    function _copyLock(
        LockedBalance memory _locked
    ) internal pure returns (LockedBalance memory) {
        return
            LockedBalance({
                amount: _locked.amount,
                end: _locked.end,
                start: _locked.start
            });
    }

    // Floors a timestamp to the nearest weekly increment
    function _floorToWeek(uint256 _t) internal pure returns (uint256) {
        return (_t / WEEK) * WEEK;
    }

    /// @inheritdoc IVeToken
    function balanceOf(address _addr) external view override returns (uint256) {
        uint256 epoch = userPointEpoch[_addr];
        if (epoch == 0 || locked[_addr].end == 0) {
            return 0;
        }

        // Casting is safe given that checkpoints are recorded in the past
        // and are more frequent than every int128.max seconds
        Point memory lastPoint = userPointHistory[_addr][epoch];
        if (locked[_addr].end > block.timestamp) {
            // When the lock has not expired yet
            lastPoint.bias +=
                lastPoint.slope *
                int128(uint128(block.timestamp - locked[_addr].start));
        } else {
            // When the lock has expired
            lastPoint.bias +=
                lastPoint.slope *
                int128(uint128(locked[_addr].end - lastPoint.ts));
        }

        return uint256(int256(lastPoint.bias));
    }

    // Calculate total supply of voting power at a given time _t
    // _point is the most recent point before time _t
    // _t is the time at which to calculate supply
    function _supplyAt(
        Point memory _point,
        uint256 _t
    ) internal view returns (uint256) {
        Point memory lastPoint = _point;
        // Floor the timestamp to weekly interval
        uint256 iterativeTime = _floorToWeek(lastPoint.ts);
        // Iterate through all weeks between _point & _t to account for slope changes
        for (uint256 i; i < 255; ) {
            iterativeTime = iterativeTime + WEEK;
            int128 dSlope = 0;
            // If week end is after timestamp, then truncate & leave dSlope to 0
            if (iterativeTime > _t) {
                iterativeTime = _t;
            }
            // else get most recent slope change
            else {
                dSlope = slopeChanges[iterativeTime];
            }

            // Casting is safe given that lastPoint.ts < iterativeTime and
            // iteration goes over 255 weeks max
            lastPoint.bias =
                lastPoint.bias +
                (lastPoint.slope *
                    int128(int256(iterativeTime - lastPoint.ts)));
            if (iterativeTime == _t) {
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
    function totalSupply() external view override returns (uint256) {
        uint256 epoch_ = globalEpoch;
        Point memory lastPoint = pointHistory[epoch_];
        return _supplyAt(lastPoint, block.timestamp);
    }

    function allowance(
        address,
        address
    ) external pure override returns (uint256) {
        revert();
    }
    function transfer(address, uint256) external pure override returns (bool) {
        revert();
    }
    function approve(address, uint256) external pure override returns (bool) {
        revert();
    }
    function transferFrom(
        address,
        address,
        uint256
    ) external pure override returns (bool) {
        revert();
    }
}
