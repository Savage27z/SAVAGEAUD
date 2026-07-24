// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISlvrGameRegistry} from "./interfaces/ISlvrGameRegistry.sol";

/// @title SlvrGameRegistry
/// @notice Governance-controlled catalog of games plugged into the SLVR protocol.
/// @dev Owner registers/retires games and tunes emission weights. A separate `guardian`
///      may only pause/unpause games (fast circuit breaker) without full ownership.
///      `totalActiveWeight` is maintained incrementally so the hub can split the shared
///      emission stream in O(1). Game ids are 1-based (0 == "not registered").
contract SlvrGameRegistry is ISlvrGameRegistry, Ownable {
    uint16 public constant BPS = 10_000;

    uint256 public gameCount;
    address public guardian;

    mapping(uint256 => GameInfo) private _games;
    mapping(address => uint256) public gameIdOf;

    uint256 public totalActiveWeight;

    error ZeroAddress();
    error AlreadyRegistered();
    error UnknownGame();
    error BadWeight();
    error NotGuardianOrOwner();
    error Retired_();

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        _;
    }

    constructor(address owner_) Ownable(owner_) {}

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianChanged(guardian_);
    }

    /// @notice Register a new game. Starts in `Pending`; call setStatus(Active) to switch it on.
    function registerGame(address game, bytes32 gameType, Tier tier, uint32 emissionWeight, uint16 maxWeightBps)
        external
        onlyOwner
        returns (uint256 gameId)
    {
        if (game == address(0)) revert ZeroAddress();
        if (gameIdOf[game] != 0) revert AlreadyRegistered();
        if (maxWeightBps == 0 || maxWeightBps > BPS) revert BadWeight();

        gameId = ++gameCount;
        _games[gameId] = GameInfo({
            game: game,
            gameType: gameType,
            status: Status.Pending,
            tier: tier,
            emissionWeight: emissionWeight,
            maxWeightBps: maxWeightBps,
            exists: true
        });
        gameIdOf[game] = gameId;

        emit GameRegistered(gameId, game, gameType, tier);
    }

    /// @notice Change a game's status. Guardian may toggle Active<->Paused; owner may do all.
    /// @dev Retired is terminal. Active-weight bookkeeping is kept in sync.
    function setStatus(uint256 gameId, Status status) external onlyGuardianOrOwner {
        GameInfo storage g = _games[gameId];
        if (!g.exists) revert UnknownGame();
        if (g.status == Status.Retired) revert Retired_();

        // Guardian is limited to the pause/unpause circuit-breaker: it may only toggle a game
        // between Active and Paused, never bring a Pending game online or resurrect a Retired one.
        if (msg.sender != owner()) {
            bool targetOk = (status == Status.Paused) || (status == Status.Active);
            bool currentOk = (g.status == Status.Active) || (g.status == Status.Paused);
            if (!targetOk || !currentOk) revert NotGuardianOrOwner();
        }

        _applyStatus(g, gameId, status);
    }

    function setEmissionWeight(uint256 gameId, uint32 emissionWeight, uint16 maxWeightBps) external onlyOwner {
        GameInfo storage g = _games[gameId];
        if (!g.exists) revert UnknownGame();
        if (maxWeightBps == 0 || maxWeightBps > BPS) revert BadWeight();

        if (g.status == Status.Active) {
            totalActiveWeight = totalActiveWeight - g.emissionWeight + emissionWeight;
        }
        g.emissionWeight = emissionWeight;
        g.maxWeightBps = maxWeightBps;
        emit GameWeightChanged(gameId, emissionWeight, maxWeightBps);
    }

    function _applyStatus(GameInfo storage g, uint256 gameId, Status status) private {
        Status old = g.status;
        if (old == status) return;

        bool wasActive = old == Status.Active;
        bool willBeActive = status == Status.Active;
        if (wasActive && !willBeActive) {
            totalActiveWeight -= g.emissionWeight;
        } else if (!wasActive && willBeActive) {
            totalActiveWeight += g.emissionWeight;
        }
        g.status = status;
        emit GameStatusChanged(gameId, status);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function gameInfo(uint256 gameId) external view returns (GameInfo memory) {
        return _games[gameId];
    }

    function isActive(address game) external view returns (bool) {
        uint256 id = gameIdOf[game];
        return id != 0 && _games[id].status == Status.Active;
    }

    function statusOf(uint256 gameId) external view returns (Status) {
        return _games[gameId].status;
    }

    function tierOf(uint256 gameId) external view returns (Tier) {
        return _games[gameId].tier;
    }

    function weightOf(uint256 gameId) external view returns (uint32) {
        return _games[gameId].emissionWeight;
    }

    function maxWeightBpsOf(uint256 gameId) external view returns (uint16) {
        return _games[gameId].maxWeightBps;
    }
}
