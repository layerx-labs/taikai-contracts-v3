// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./IVeToken.sol";
import "./IVeTokenSettings.sol";

/// @title VeToken
/// @notice This contract represents a token with locking functionality.
contract VeToken is IVeToken, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum ActionType {
        DEPOSIT,
        INCREASE_LOCK_AMOUNT
    }

    // Define the Deposit event
    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 indexed locktime,
        ActionType indexed actionType,
        uint256 ts
    );

    // Define the Withdraw event
    event Withdraw(address indexed provider, uint256 value, uint256 ts);

    // Define the Supply event
    event Supply(uint256 prevSupply, uint256 supply);

    struct Point {
        int128 bias;
        int128 slope; // - dweight / dt
        uint256 ts;
        uint256 blk; // block
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    // Define constants
    uint256 private constant WEEK = 1 weeks; // All future times are rounded by week
    uint256 private constant MULTIPLIER = 10 ** 18;
    address constant ZERO_ADDRESS = address(0);

    // State variables
    address public token;
    uint256 private supply;

    // Token metadata
    string public name;
    string public symbol;
    string public version;
    uint8 public decimals;
    address public settings;

    uint256 private epoch;
    mapping(address => LockedBalance) public locked;
    mapping(uint256 => Point) private point_history;
    mapping(address => mapping(uint256 => Point)) private user_point_history;
    mapping(address => uint256) private user_point_epoch;
    mapping(uint256 => int128) private slope_changes;

    /**
        @notice Constructor to initialize the VeToken contract.
        @param _token_addr The address of the token (Eg.: TKAI address).
        @param _name The name for this VeToken.
        @param _symbol The symbol for this VeToken.
        @param _version The version for this VeToken.
        @param _settings The address for the settings contract.
    */
    constructor(
        address _token_addr,
        string memory _name,
        string memory _symbol,
        string memory _version,
        address _settings
    ) Ownable() ReentrancyGuard() {
        token = _token_addr;
        point_history[0].blk = block.number;
        point_history[0].ts = block.timestamp;

        uint8 decimals_ = IERC20Metadata(_token_addr).decimals();
        settings = _settings;
        require(
            _token_addr != address(0),
            "_token_addr cannot be zero address"
        );
        require(
            decimals_ <= 255,
            "Decimals should be less than or equal to 255"
        );
        decimals = decimals_;
        name = _name;
        symbol = _symbol;
        version = _version;
    }

    /**
        @dev Calculate the percentage of a number.
        @param whole The whole number.
        @param percentage The percentage.
        NOTE: The percentage must be multiplied by 100 to avoid floating point numbers.
                Eg.: 10% should be passed as 1000. 100% should be passed as 10000.
        @return The percentage of the whole number.
     */
    function calculatePercentage(
        uint256 whole,
        uint16 percentage
    ) internal pure returns (uint256) {
        return (whole * percentage) / 10000;
    }

    /// @inheritdoc IVeToken
    function getLastUserSlope(
        address addr
    ) external view override returns (int128) {
        uint256 uepoch = user_point_epoch[addr];
        return user_point_history[addr][uepoch].slope;
    }

    /// @inheritdoc IVeToken
    function userPointHistoryTs(
        address addr,
        uint256 idx
    ) external view override returns (uint256) {
        return user_point_history[addr][idx].ts;
    }

    /// @inheritdoc IVeToken
    function lockedEnd(address addr) external view override returns (uint256) {
        return locked[addr].end;
    }

    /**
        @dev Check if the given address is a zero address.
        @param addr The address to check.
        @return True if the address is a zero address, otherwise false.
     */
    function isZeroAddress(address addr) internal pure returns (bool) {
        return addr == ZERO_ADDRESS;
    }

    /// @inheritdoc IVeToken
    function checkpoint() external override {
        _checkpoint(ZERO_ADDRESS, LockedBalance(0, 0), LockedBalance(0, 0));
    }

    /// @inheritdoc IVeToken
    function deposit(uint256 _value) external override nonReentrant {
        require(msg.sender == tx.origin, "No contracts allowed");
        require(_value > 0, "Need non-zero value");
        LockedBalance memory _locked = locked[msg.sender];

        if (_locked.amount > 0) {
            require(
                _locked.end > block.timestamp,
                "Cannot add to expired lock. Withdraw"
            );

            _depositFor(
                msg.sender,
                _value,
                0,
                _locked,
                ActionType.INCREASE_LOCK_AMOUNT
            );
        } else {
            uint256 currentTime = block.timestamp;
            uint256 unlock_time = ((currentTime +
                uint256(int256(IVeTokenSettings(settings).locktime()))) /
                WEEK) * WEEK; // Locktime rounded down to weeks

            require(currentTime >= 0, "Current time exceeds int128 limits");
            require(_locked.amount == 0, "Withdraw old tokens first");

            _depositFor(
                msg.sender,
                _value,
                unlock_time,
                _locked,
                ActionType.DEPOSIT
            );
        }
    }

    /// @inheritdoc IVeToken
    function withdraw() external override nonReentrant {
        LockedBalance memory _locked = locked[msg.sender];

        uint256 value = uint256(int256(_locked.amount));

        LockedBalance memory old_locked = _locked;
        _locked.end = 0;
        _locked.amount = 0;
        locked[msg.sender] = _locked;
        uint256 supply_before = supply;
        supply = supply_before - value;

        _checkpoint(msg.sender, old_locked, _locked);

        IERC20(token).safeTransfer(msg.sender, value);

        emit Withdraw(msg.sender, value, block.timestamp);
        emit Supply(supply_before, supply_before - value);
    }

    /// @inheritdoc IVeToken
    function balanceOf(address addr) external view override returns (uint256) {
        uint256 _epoch = user_point_epoch[addr];
        if (_epoch == 0 || locked[addr].end == 0) {
            return 0;
        } else {
            Point memory last_point = user_point_history[addr][_epoch];

            if (locked[addr].end > block.timestamp) {
                // When the lock has not expired yet
                uint256 timeDiff = (block.timestamp - last_point.ts);

                last_point.bias +=
                    last_point.slope *
                    int128(
                        uint128(
                            calculatePercentage(
                                timeDiff,
                                10000 -
                                    IVeTokenSettings(settings)
                                        .advancePercentage()
                            )
                        )
                    );
            } else {
                // When the lock has expired
                uint256 timeDiff = (locked[addr].end - last_point.ts);

                last_point.bias +=
                    last_point.slope *
                    int128(
                        uint128(
                            calculatePercentage(
                                timeDiff,
                                10000 -
                                    IVeTokenSettings(settings)
                                        .advancePercentage()
                            )
                        )
                    );
            }

            return uint256(int256(last_point.bias));
        }
    }

    /// @inheritdoc IVeToken
    function balanceOfAt(
        address addr,
        uint256 _block
    ) external view override returns (uint256) {
        require(_block <= block.number, "Block number too high");

        uint256 _min = 0;
        uint256 _max = user_point_epoch[addr];
        for (uint256 i = 0; i < 128; i++) {
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (user_point_history[addr][_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        Point memory upoint = user_point_history[addr][_min];
        uint256 max_epoch = epoch;
        uint256 _epoch = _findBlockEpoch(_block, max_epoch);
        Point memory point_0 = point_history[_epoch];
        uint256 d_block = 0;
        uint256 d_t = 0;
        if (_epoch < max_epoch) {
            Point memory point_1 = point_history[_epoch + 1];
            d_block = point_1.blk - point_0.blk;
            d_t = point_1.ts - point_0.ts;
        } else {
            d_block = block.number - point_0.blk;
            d_t = block.timestamp - point_0.ts;
        }
        uint256 block_time = point_0.ts;
        if (d_block != 0) {
            block_time += (d_t * (_block - point_0.blk)) / d_block;
        }

        uint256 timeDiff = block_time - upoint.ts;
        upoint.bias +=
            upoint.slope *
            int128(
                uint128(
                    calculatePercentage(
                        timeDiff,
                        10000 - IVeTokenSettings(settings).advancePercentage()
                    )
                )
            );
        if (upoint.bias >= 0) {
            return uint256(int256(upoint.bias));
        } else {
            return 0;
        }
    }

    /// @inheritdoc IVeToken
    function totalLocked() external view returns (uint256) {
        return supply;
    }

    /**
        @notice add checkpoints to pointHistory for every week from last added checkpoint until now
        @dev block number for each added checkpoint is estimated by their respective timestamp and the blockslope
            where the blockslope is estimated by the last added time/block point and the current time/block point
        @dev pointHistory include all weekly global checkpoints and some additional in-week global checkpoints
    */
    function _updatePoints(Point memory last_point) internal {
        uint256 _epoch = epoch;
        uint256 last_checkpoint = last_point.ts;
        // initial_last_point is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        Point memory initial_last_point = last_point;
        uint256 block_slope = 0; // dblock/dt
        if (block.timestamp > last_point.ts) {
            block_slope =
                (MULTIPLIER * (block.number - last_point.blk)) /
                (block.timestamp - last_point.ts);
        }
        // Go over weeks to fill history and calculate what the current point is
        uint256 t_i = (last_checkpoint / WEEK) * WEEK;

        for (uint256 i = 0; i < 255; i++) {
            // Hopefully it won't happen that this won't get used in 5 years!
            // If it does, users will be able to withdraw but vote weight will be broken
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > block.timestamp) {
                t_i = block.timestamp;
            } else {
                d_slope = slope_changes[t_i];
            }

            last_point.bias +=
                last_point.slope *
                int128(int256(t_i) - int256(last_checkpoint));

            last_point.slope += d_slope;
            if (last_point.bias < 0) {
                // This can happen
                last_point.bias = 0;
            }

            if (last_point.slope < 0) {
                // This cannot happen - just in case
                last_point.slope = 0;
            }
            last_checkpoint = t_i;
            last_point.ts = t_i;
            last_point.blk =
                initial_last_point.blk +
                (block_slope * (t_i - initial_last_point.ts)) /
                MULTIPLIER;
            _epoch += 1;
            if (t_i == block.timestamp) {
                last_point.blk = block.number;
                break;
            } else {
                point_history[_epoch] = last_point;
            }
        }

        epoch = _epoch;
    }

    /// @notice Record global and per-user data to checkpoint
    /// @param addr User wallet address. No user checkpoint if 0x0
    /// @param old_locked Previous locked balance / end lock time for the user
    /// @param new_locked New locked balance / end lock time for the user
    function _checkpoint(
        address addr,
        LockedBalance memory old_locked,
        LockedBalance memory new_locked
    ) internal {
        Point memory u_old;
        Point memory u_new;
        int128 old_dslope = 0;
        int128 new_dslope = 0;
        uint256 _epoch = epoch;

        if (!isZeroAddress(addr)) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            if (old_locked.end > block.timestamp && old_locked.amount > 0) {
                u_old.slope =
                    old_locked.amount /
                    IVeTokenSettings(settings).locktime();
                u_old.bias = int128(
                    uint128(
                        calculatePercentage(
                            uint256(uint128(u_old.slope)) *
                                (old_locked.end - block.timestamp),
                            IVeTokenSettings(settings).advancePercentage()
                        )
                    )
                );
            }

            if (new_locked.end > block.timestamp && new_locked.amount > 0) {
                u_new.slope =
                    new_locked.amount /
                    IVeTokenSettings(settings).locktime();
                u_new.bias = int128(
                    uint128(
                        calculatePercentage(
                            uint256(uint128(u_new.slope)) *
                                (new_locked.end - block.timestamp),
                            IVeTokenSettings(settings).advancePercentage()
                        )
                    )
                );
            }

            // Read values of scheduled changes in the slope
            // old_locked.end can be in the past and in the future
            // new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
            old_dslope = slope_changes[old_locked.end];

            if (new_locked.end != 0) {
                if (new_locked.end == old_locked.end) {
                    new_dslope = old_dslope;
                } else {
                    new_dslope = slope_changes[new_locked.end];
                }
            }
        }

        Point memory last_point = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });

        if (_epoch > 0) {
            last_point = point_history[_epoch];
        }

        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        _updatePoints(last_point);

        if (!isZeroAddress(addr)) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            last_point.slope += (u_new.slope - u_old.slope);
            last_point.bias += (u_new.bias - u_old.bias);
            if (last_point.slope < 0) {
                last_point.slope = 0;
            }
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
        }

        // Record the changed point into history
        point_history[_epoch] = last_point;

        if (!isZeroAddress(addr)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (old_locked.end > block.timestamp) {
                // old_dslope was <something> - u_old.slope, so we cancel that
                old_dslope += u_old.slope;
                if (new_locked.end == old_locked.end) {
                    old_dslope -= u_new.slope; // It was a new deposit, not extension
                }
                slope_changes[old_locked.end] = old_dslope;
            }

            if (new_locked.end > block.timestamp) {
                if (new_locked.end > old_locked.end) {
                    new_dslope -= u_new.slope; // old slope disappeared at this point
                    slope_changes[new_locked.end] = new_dslope;
                }
                // else: we recorded it already in old_dslope
            }

            // Now handle user history
            uint256 user_epoch = user_point_epoch[addr] + 1;

            user_point_epoch[addr] = user_epoch;
            u_new.ts = block.timestamp;
            u_new.blk = block.number;
            user_point_history[addr][user_epoch] = u_new;
        }
    }

    /// @notice Deposit and lock tokens for a user
    /// @param _addr Address of the user
    /// @param _value Amount of tokens to deposit
    /// @param unlock_time Time when the tokens will be unlocked
    /// @param locked_balance Previous locked balance of the user / timestamp
    /// @param _action_type Type of action
    function _depositFor(
        address _addr,
        uint256 _value,
        uint256 unlock_time,
        LockedBalance memory locked_balance,
        ActionType _action_type
    ) internal {
        LockedBalance memory _locked = locked_balance;
        uint256 supply_before = supply;

        supply = supply_before + _value;
        LockedBalance memory old_locked = _locked;

        _locked.amount += int128(int256(_value));
        if (unlock_time != 0) {
            _locked.end = unlock_time;
        }
        locked[_addr] = _locked;

        _checkpoint(_addr, old_locked, _locked);

        if (_value != 0) {
            IERC20(token).safeTransferFrom(_addr, address(this), _value);
        }

        emit Deposit(_addr, _value, _locked.end, _action_type, block.timestamp);
        emit Supply(supply_before, supply);
    }

    /// @notice Binary search to estimate timestamp for block number
    /// @param _block Block number to estimate timestamp for
    /// @param max_epoch Don't go beyond this epoch
    /// @return Estimated timestamp for block number
    function _findBlockEpoch(
        uint256 _block,
        uint256 max_epoch
    ) internal view returns (uint256) {
        uint256 _min = 0;
        uint256 _max = max_epoch;

        for (uint256 i = 0; i < 128; i++) {
            // 128 iterations will always be enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }

            uint256 _mid = (_min + _max + 1) / 2;
            if (point_history[_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        return _min;
    }
}
