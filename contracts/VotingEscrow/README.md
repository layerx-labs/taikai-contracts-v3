# VeToken Contract

This Solidity smart contract, VeToken, is an implementation of a voting escrow system inspired by Curve's voting escrow model. It is designed to manage time-weighted voting power for users who lock their tokens for a specified period. The contract allows users to lock tokens, increase the amount of locked tokens, extend the lock duration, and withdraw tokens once the lock period has expired. The voting power of a user is determined by the amount of tokens locked and the duration of the lock, with the voting weight decaying linearly over time.

## Key Features and Specifications:

1. Token Locking: Users can lock a specified amount of tokens for a period, gaining voting power proportional to the amount and duration of the lock.
2. Time-Weighted Voting: The voting power is time-weighted, meaning it decreases linearly as the lock period progresses.
3. Lock Management: Users can:
    * Deposit tokens for an existing lock.
    * Create a new lock with a specified unlock time.
    * Increase the amount of tokens in an existing lock.
    * Extend the lock duration.
4. Withdrawals: Users can withdraw their tokens once the lock period has expired.
5. Global and User Checkpoints: The contract maintains a history of global and user-specific checkpoints to track changes in voting power over time.
6. Events: The contract emits events for user actions like deposits, withdrawals, and checkpoints, allowing for easy tracking of state changes.
7. Security: The contract uses OpenZeppelin's ReentrancyGuard and Ownable for security and access control, preventing reentrancy attacks and ensuring only the owner can perform certain actions.
Error Handling: The contract includes custom error messages for various invalid operations, such as attempting to lock tokens in the past or trying to withdraw before the lock expires.

Overall, this contract is designed to facilitate decentralized governance by allowing users to lock tokens and gain voting power, incentivizing long-term commitment to the protocol.

## Contract Functions

```
 +  VeToken (IVeToken, Ownable, ReentrancyGuard)
    - [Pub] <Constructor> #
       - modifiers: Ownable,ReentrancyGuard
    - [Ext] name
    - [Ext] symbol
    - [Ext] decimals
    - [Ext] version
    - [Ext] totalLocked
    - [Ext] getEpoch
    - [Ext] token
    - [Ext] getLastUserSlope
    - [Ext] getUserPointHistoryTS
    - [Ext] lockedEnd
    - [Ext] lockedBalance
    - [Ext] totalSupplyAt
    - [Pub] balanceOf
    - [Ext] balanceOf
    - [Ext] balanceOfAt
    - [Ext] totalSupply
    - [Pub] totalSupply
    - [Ext] checkpoint #
    - [Ext] depositFor #
       - modifiers: nonReentrant
    - [Ext] createLock #
       - modifiers: nonReentrant
    - [Ext] increaseAmount #
       - modifiers: nonReentrant
    - [Ext] increaseUnlockTime #
    - [Ext] withdraw #
       - modifiers: nonReentrant
    - [Pub] estimateDeposit
    - [Int] _checkpoint #
    - [Int] _depositFor #
    - [Int] _supplyAt
    - [Int] _findBlockEpoch
    - [Int] _findUserTimestampEpoch
    - [Int] _validateLockTime
    - [Int] _findGlobalTimestampEpoch
    - [Prv] _updateGlobalPoint #
```