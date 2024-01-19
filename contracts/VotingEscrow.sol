// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/IVeToken.sol";

contract VeToken is IVeToken, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum ActionType {
        DEPOSIT_FOR, // 0
        CREATE_LOCK, // 1
        INCREASE_LOCK_AMOUNT, // 2
        INCREASE_UNLOCK_TIME // 3
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
    uint256 public constant WEEK = 1 weeks; // All future times are rounded by week
    int128 public constant MAXTIME = 4 * 365 days; // 4 years
    uint256 public constant MULTIPLIER = 10 ** 18;

    // State variables
    address public token;
    uint256 public supply;

    // Token metadata
    string public name;
    string public symbol;
    string public version;
    uint8 public decimals;

    uint16 advance_percentage = 1000; // 10%, the last 2 digits are the decimals part

    mapping(address => LockedBalance) public locked;

    uint256 public epoch;
    // Point is assumed to be a struct. Replace '100000000000000000000000000000' with an appropriate value or logic
    mapping(uint256 => Point) public point_history;
    // Assuming Point is a struct. Replace '1000000000' with an appropriate size or logic
    mapping(address => mapping(uint256 => Point)) public user_point_history;
    mapping(address => uint256) public user_point_epoch;
    // Assuming int128 is a type alias or you're using int256 instead
    mapping(uint256 => int128) public slope_changes;
    address constant ZERO_ADDRESS = address(0);

    constructor(
        address _token_addr,
        string memory _name,
        string memory _symbol,
        string memory _version
    ) Ownable() ReentrancyGuard() {
        token = _token_addr;
        point_history[0].blk = block.number;
        point_history[0].ts = block.timestamp;

        uint8 decimals_ = IERC20Metadata(_token_addr).decimals();
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

    function setAdvancePercentage(
        uint16 _advance_percentage
    ) external onlyOwner {
        require(
            _advance_percentage <= 10000 && _advance_percentage >= 0,
            "advance_percentage should be between 0 and 10000"
        );
        advance_percentage = _advance_percentage;
    }

    function calculatePercentage(
        uint256 whole,
        uint16 percentage
    ) internal pure returns (uint256) {
        return (whole * percentage) / 10000;
    }

    function getLastUserSlope(
        address addr
    ) external view override returns (int128) {
        uint256 uepoch = user_point_epoch[addr];
        return user_point_history[addr][uepoch].slope;
    }

    function userPointHistoryTs(
        address addr,
        uint256 idx
    ) external view override returns (uint256) {
        return user_point_history[addr][idx].ts;
    }

    function lockedEnd(address addr) external view override returns (uint256) {
        return locked[addr].end;
    }

    function isZeroAddress(address addr) public pure returns (bool) {
        return addr == ZERO_ADDRESS;
    }

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
                u_old.slope = old_locked.amount / MAXTIME;
                u_old.bias =
                    int128(u_old.slope) *
                    int128(int256(old_locked.end) - int256(block.timestamp));
            }

            if (new_locked.end > block.timestamp && new_locked.amount > 0) {
                u_new.slope = new_locked.amount / MAXTIME;
                u_new.bias =
                    int128(u_new.slope) *
                    int128(int256(new_locked.end) - int256(block.timestamp));
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
        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

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

            last_point.bias -=
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
        // Now point_history is filled until t=now

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
        emit Supply(supply_before, supply + _value);
    }

    function checkpoint() external override {
        _checkpoint(ZERO_ADDRESS, LockedBalance(0, 0), LockedBalance(0, 0));
    }

    function depositFor(
        address _addr,
        uint256 _value
    ) external override nonReentrant {
        LockedBalance memory _locked = locked[_addr];

        require(_value > 0, "Need non-zero value");
        require(_locked.amount > 0, "No existing lock found");
        require(
            _locked.end > block.timestamp,
            "Cannot add to expired lock. Withdraw"
        );

        _depositFor(_addr, _value, 0, locked[_addr], ActionType.DEPOSIT_FOR);
    }

    function createLock(
        uint256 _value,
        uint256 _unlock_time
    ) external override nonReentrant {
        require(msg.sender == tx.origin, "No contracts allowed");

        uint256 unlock_time = (_unlock_time / WEEK) * WEEK; // Locktime rounded down to weeks
        uint256 currentTime = block.timestamp;
        LockedBalance memory _locked = locked[msg.sender];

        require(currentTime >= 0, "Current time exceeds int128 limits");
        require(_value > 0, "Need non-zero value");
        require(_locked.amount == 0, "Withdraw old tokens first");
        require(
            unlock_time > block.timestamp,
            "Can only lock until time in the future"
        );
        require(
            unlock_time <= currentTime + uint256(int256(MAXTIME)),
            "Voting lock can be 4 years max"
        );

        _depositFor(
            msg.sender,
            _value,
            unlock_time,
            _locked,
            ActionType.CREATE_LOCK
        );
    }

    function increaseAmount(uint256 _value) external override nonReentrant {
        LockedBalance memory _locked = locked[msg.sender];

        require(_value > 0, "Need non-zero value");
        require(_locked.amount > 0, "No existing lock found");
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
    }

    function increaseUnlockTime(
        uint256 _unlock_time
    ) external override nonReentrant {
        LockedBalance memory _locked = locked[msg.sender];
        uint256 unlock_time = (_unlock_time / WEEK) * WEEK; // Locktime rounded down to weeks
        int128 currentTime = int128(uint128(block.timestamp));

        require(_locked.end > block.timestamp, "Lock expired");
        require(_locked.amount > 0, "Nothing is locked");
        require(unlock_time > _locked.end, "Can only increase lock duration");
        require(
            unlock_time <=
                uint256(int256(currentTime)) + uint256(int256(MAXTIME)),
            "Voting lock can be 4 years max"
        );

        _depositFor(
            msg.sender,
            0,
            unlock_time,
            _locked,
            ActionType.INCREASE_UNLOCK_TIME
        );
    }

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

    function findBlockEpoch(
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

    function balanceOf(address addr) external view override returns (uint256) {
        uint256 _epoch = user_point_epoch[addr];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory last_point = user_point_history[addr][_epoch];
            uint256 timeDiff = (block.timestamp - last_point.ts);

            if (timeDiff < 0) {
                // Handle negative time difference, if applicable
                timeDiff = 0;
            }

            last_point.bias -=
                last_point.slope *
                int128(
                    uint128(
                        calculatePercentage(
                            timeDiff,
                            10000 - advance_percentage
                        )
                    )
                );
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }

            return uint256(int256(last_point.bias));
        }
    }

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
        uint256 _epoch = findBlockEpoch(_block, max_epoch);
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
        upoint.bias -=
            upoint.slope *
            int128(
                uint128(
                    calculatePercentage(timeDiff, 10000 - advance_percentage)
                )
            );
        if (upoint.bias >= 0) {
            return uint256(int256(upoint.bias));
        } else {
            return 0;
        }
    }

    function supplyAt(
        Point memory point,
        uint256 t
    ) internal view returns (uint256) {
        Point memory last_point = point;
        uint256 t_i = (last_point.ts / WEEK) * WEEK;

        for (uint256 i = 0; i < 255; i++) {
            t_i += WEEK;
            int128 d_slope = 0;

            if (t_i > t) {
                t_i = t;
            } else {
                d_slope = slope_changes[t_i];
            }

            int128 timeDiff = int128(int256(t_i) - int256(last_point.ts));
            last_point.bias -= last_point.slope * timeDiff;

            if (t_i == t) {
                break;
            }

            last_point.slope += d_slope;
            last_point.ts = t_i;
        }

        if (last_point.bias < 0) {
            last_point.bias = 0;
        }

        return uint256(int256(last_point.bias));
    }

    function totalLocked() external view returns (uint256) {
        return supply;
    }

    function totalSupply() external view override returns (uint256) {
        uint256 _epoch = epoch;
        Point memory last_point = point_history[_epoch];
        return supplyAt(last_point, block.timestamp);
    }

    function totalSupplyAt(
        uint256 _block
    ) external view override returns (uint256) {
        require(_block <= block.number, "Block number is too high");

        uint256 _epoch = epoch;
        uint256 target_epoch = findBlockEpoch(_block, _epoch);

        Point memory point = point_history[target_epoch];
        uint256 dt = 0;

        if (target_epoch < _epoch) {
            Point memory point_next = point_history[target_epoch + 1];
            if (point.blk != point_next.blk) {
                dt =
                    ((_block - point.blk) * (point_next.ts - point.ts)) /
                    (point_next.blk - point.blk);
            }
        } else {
            if (point.blk != block.number) {
                dt =
                    ((_block - point.blk) * (block.timestamp - point.ts)) /
                    (block.number - point.blk);
            }
        }

        return supplyAt(point, point.ts + dt);
    }
}
