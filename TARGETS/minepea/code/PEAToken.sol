// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";

contract Pea is ERC20, ERC20Permit, Ownable {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ============ Constants ============

    uint256 public constant MAX_SUPPLY = 3_000_000 * 1e18;

    // ============ State ============

    uint256 public totalMinted;
    address public minter;
    bool public minterFrozen;
    bool public limited = true;

    // V4 Pool
    IPoolManager public immutable poolManager;
    PoolId public poolId;
    bool public poolIdSet;
    bool public peaIsToken0;

    // TWAP State
    struct TickSnapshot {
        int24 tick;
        uint32 timestamp;
    }

    uint256 public constant MIN_SNAPSHOT_INTERVAL = 12;

    TickSnapshot[5] public tickHistory;
    mapping(address => bool) private _isPea;
    mapping(address => bool) public _isExcluded;
    mapping(address => bool) private _isAMMPool;
    uint8 public currentSnapshotIndex;
    uint256 private lastTickUpdateTime;

    // ============ Events ============

    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event MinterFrozen(address indexed minter);
    event PoolIdUpdated(PoolId indexed poolId);

    // ============ Errors ============

    error NotMinter();
    error MinterAlreadyFrozen();
    error ExceedsMaxSupply();
    error TWAPNotReady();
    error ZeroAddress();
    error PoolIdAlreadySet();

    // ============ Constructor ============

    constructor(
        address[] memory _Peas,
        address _poolManager
    ) ERC20("MinePea", "PEA") ERC20Permit("MinePea") Ownable(msg.sender) {
        if (_poolManager == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(_poolManager);

        uint256 initialMint = 10_000 * 1e18;
        _mint(msg.sender, initialMint);
        totalMinted = initialMint;
        _setPeas(_Peas, true);

        _isExcluded[_msgSender()] = true;
        _isExcluded[address(this)] = true;
        _isAMMPool[address(poolManager)] = true;
    }

    // ============ Admin Functions ============

    function setMinter(address _minter) external onlyOwner {
        if (minterFrozen) revert MinterAlreadyFrozen();
        if (_minter == address(0)) revert ZeroAddress();

        address oldMinter = minter;
        minter = _minter;

        emit MinterUpdated(oldMinter, _minter);
    }

    function freezeMinter() external onlyOwner {
        if (minterFrozen) revert MinterAlreadyFrozen();

        minterFrozen = true;

        emit MinterFrozen(minter);
    }

    function _setPeas(address[] memory _Peas, bool _status) internal {
        for (uint i = 0; i < _Peas.length; i++) {
            _isPea[_Peas[i]] = _status;
        }
    }

    function removeLimits() external onlyOwner {
        limited = false;
    }

    /// @notice Set the V4 pool ID after creating the pool via PoolManager.initialize()
    /// @dev Can only be called once. Determines token ordering for price calculations.
    function setPoolId(PoolId _poolId) external onlyOwner {
        if (poolIdSet) revert PoolIdAlreadySet();
        poolId = _poolId;
        poolIdSet = true;

        // Native ETH = address(0), always lower than any contract address
        peaIsToken0 = false;

        emit PoolIdUpdated(_poolId);
    }

    // ============ Minting ============

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        if (totalMinted + amount > MAX_SUPPLY) revert ExceedsMaxSupply();

        totalMinted += amount;
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ============ Transfer Override for TWAP ============

    function _update(address from, address to, uint256 value) internal override {
        
        if (_isAMMPool[from] || _isAMMPool[to]) {
            if (!_isExcluded[to] && !_isExcluded[from] && limited) {
                require(_isPea[to] || _isPea[from], "Not Allowed");
            }
            _updateTickSnapshot();
        }

        super._update(from, to, value);
    }

    // ============ TWAP Functions ============

    /// @notice Update the tick snapshot from V4 pool (called on AMM interactions)
    function _updateTickSnapshot() private {
        if (block.timestamp < lastTickUpdateTime + MIN_SNAPSHOT_INTERVAL) return;
        if (!poolIdSet) return;

        lastTickUpdateTime = block.timestamp;

        // Read current tick from V4 PoolManager via StateLibrary (extsload)
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        currentSnapshotIndex = uint8((currentSnapshotIndex + 1) % 5);
        tickHistory[currentSnapshotIndex] = TickSnapshot({
            tick: tick,
            timestamp: uint32(block.timestamp)
        });
    }

    /// @notice Calculate TWAP tick from snapshots
    /// @return twapTick Arithmetic mean of stored ticks (= geometric mean of prices)
    function getOracleTWAP() public view returns (int24 twapTick) {
        int256 tickSum;
        uint256 count;

        for (uint256 i = 0; i < 5; i++) {
            if (tickHistory[i].timestamp == 0) continue;
            tickSum += tickHistory[i].tick;
            count++;
        }

        if (count < 5) revert TWAPNotReady();
        twapTick = int24(tickSum / int256(count));
    }

    /// @notice Get expected PEA output for a given ETH input using TWAP
    /// @param ethAmount Amount of ETH (in wei)
    /// @return expectedPEA Expected PEA output based on TWAP price
    function getTWAPAmountOut(uint256 ethAmount) external view returns (uint256 expectedPEA) {
        int24 twapTick = getOracleTWAP();
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);

        // Overflow-safe price calc (mirrors Uniswap V3 OracleLibrary)
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            expectedPEA = peaIsToken0
                ? FullMath.mulDiv(1 << 192, ethAmount, ratioX192)
                : FullMath.mulDiv(ratioX192, ethAmount, 1 << 192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            expectedPEA = peaIsToken0
                ? FullMath.mulDiv(1 << 128, ethAmount, ratioX128)
                : FullMath.mulDiv(ratioX128, ethAmount, 1 << 128);
        }
    }

    /// @notice Check if TWAP is ready (has 5 snapshots)
    function isTWAPReady() external view returns (bool ready) {
        uint256 count;
        for (uint256 i = 0; i < 5; i++) {
            if (tickHistory[i].timestamp != 0) count++;
        }
        return count >= 5;
    }

    /// @notice Get current spot price vs TWAP price deviation
    /// @return spotTick Current pool tick
    /// @return twapTick Average tick from snapshots
    /// @return deviationTicks Absolute difference in ticks
    function getPriceDeviation() external view returns (
        int24 spotTick,
        int24 twapTick,
        uint24 deviationTicks
    ) {
        if (!poolIdSet) return (0, 0, 0);

        (, spotTick,,) = poolManager.getSlot0(poolId);
        twapTick = getOracleTWAP();

        int24 diff = spotTick - twapTick;
        deviationTicks = diff >= 0 ? uint24(diff) : uint24(-diff);
    }

    // ============ View Functions ============

    /// @notice Get all tick snapshots
    function getTickHistory() external view returns (TickSnapshot[5] memory snapshots) {
        return tickHistory;
    }
}
