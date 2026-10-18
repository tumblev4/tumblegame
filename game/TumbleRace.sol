// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice What the race reads from the pool's hook, Programmable's ProtectedNative30HookV1 (views only).
interface IProtectedHook {
    function token() external view returns (address);
    function feeVault() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
}

interface ICreatorVault {
    function creatorAccrued() external view returns (uint256);
    function creatorRecipient() external view returns (address);
    function claimCreator() external returns (uint256);
}

interface IEthUsdFeed {
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @title TumbleRace
/// @notice TUMBLE's race and its pot. The token is Programmable's ProtectedLaunchTokenV1 and the pool's hook their
///         ProtectedNative30HookV1: every trade pays 3%, 0.3% to Programmable and 2.7% to the creator. The creator share
///         reaches this contract either straight from the hook's fee vault (when this contract is the vault's creator
///         recipient) or forwarded from the launch wallet. Of everything that arrives, 20/27 (2% of the trades) is the
///         pot and 7/27 (0.7%) goes to the operations wallet, fixed at deployment, which keeps the game running.
///
///         Tumblers. A wallet joins the race with join(): it needs at least `minimumToJoin()` tokens, what JOIN_VALUE
///         (0.0095 ETH, a 0.01 ETH buy after the fee) buys at the pool's price, and that amount is remembered as the
///         wallet's keepAtLeast. One tumbler per wallet; only wallets (no code, or an EIP-7702 delegation). The tumbler
///         runs from the next race that starts, and in every race after it while the wallet keeps at least keepAtLeast
///         tokens: below that it is out. The start itself checks every wallet that joined since the last start, in the
///         start's own transaction: one that holds its line runs from this race on, one that does not loses its tumbler.
///         So tokens passed from wallet to wallet before a start make one tumbler, whoever starts the race. The contract
///         cannot see the token's transfers, so later the check is made when it matters: anyone may prune() wallets that
///         fell below their line (the keeper does as soon as it sees one), and the drawn winner must hold the line at the
///         payout. leave() takes a tumbler out at once. Slots keep their place: a freed slot is filled by the next join.
///
///         Every RACE_EVERY a race: the winner takes the prize, at most a cap that grows with the pot at Chainlink's
///         ETH/USD price: $50 for every full $500 in the pot ($50 below $1,000, $100 at $1,000, $200 at $2,000, ...), up
///         to $1,000 from $10,000 (see _maxPrize). The rest of the pot waits for the next races. A race waits while the
///         pot holds less than MIN_POT or nobody is racing.
///
///         The draw: the RANDAO value of the block DRAW_DELAY blocks after the start (its prevRandao, the header's
///         mixHash), which nobody knows when the race starts and which the beacon chain sets: the block's builder can
///         change the block's hash (extraData, the transactions) but not this. Whoever finishes the race passes that
///         block's RLP header; it must hash to the block's hash (BLOCKHASH, or the EIP-2935 history contract up to 8191
///         blocks back). The draw goes over the tumbler slots as they were at the start.
///
///         race() runs it all (collect the fees, prune, finish the race whose draw block has passed, start the next one)
///         and anyone may call it. TUMBLE's keeper calls it on time and pays the gas itself: nothing for gas comes out
///         of the pot. No owner and nothing to change.
contract TumbleRace is ReentrancyGuardTransient {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    uint256 public constant RACE_EVERY = 15 minutes;
    uint256 public constant DRAW_DELAY = 5; // blocks from a race's start to its draw block
    uint256 public constant MAX_JOIN_CHECKS = 500; // joins checked by one start; more wait for the next start
    uint256 public constant JOIN_VALUE = 0.0095 ether; // the tokens to hold: what a 0.01 ETH buy leaves after the 3% fee
    uint256 public constant MAX_TRIES = 256; // slot numbers tried per draw
    uint256 public constant OPERATIONS_SHARE = 7; // out of CREATOR_SHARE: 0.7% of a trade out of the creator's 2.7%
    uint256 public constant CREATOR_SHARE = 27;
    uint256 public constant PRIZE_STEP_USD = 50e8; // Chainlink's 8 decimals
    uint256 public constant POT_STEP_USD = 500e8; // the cap grows by PRIZE_STEP_USD for every full POT_STEP_USD of pot
    uint256 public constant MAX_PRIZE_STEPS = 20; // at most $1,000 a race
    uint256 public constant FALLBACK_MAX_PRIZE = 0.02 ether; // about the smallest prize, until the feed has answered once
    uint256 public constant PRICE_MAX_AGE = 6 hours; // an older answer is not used
    uint256 public constant MIN_POT = 0.001 ether;
    IEthUsdFeed public constant ETH_USD = IEthUsdFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    /// EIP-2935 system contract: hashes of the last 8191 blocks (about 27 hours).
    address internal constant BLOCK_HASH_HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    struct Pending {
        uint64 id;
        uint64 drawBlock;
        uint64 startedAt;
        uint64 slots;
    }

    struct Tumbler {
        address owner; // 0: an empty slot
        uint48 since; // when the wallet joined
        uint48 fromRace; // the first race it runs in, set by that race's start; WAITING until then
    }

    uint48 public constant WAITING = type(uint48).max; // a tumbler that has not been checked in by a start yet

    IERC20 public immutable token;
    IProtectedHook public immutable hook;
    ICreatorVault public immutable vault;
    PoolId public immutable poolId;
    address public immutable operations;

    uint256 public operationsOwed; // the operations share, not paid yet
    uint256 public booked; // the balance already split between operations and the pot
    uint256 public nextRaceAt;
    uint256 public races; // races started
    uint256 public paidToWinners;
    uint256 public lastPrice; // the last fresh ETH/USD answer (8 decimals)
    Pending public pending; // id 0: no race waiting for its draw

    Tumbler[] private _tumblers;
    uint256[] private _emptySlots;
    address[] private _joins; // every join in order; the next start checks the ones from joinsChecked on
    uint256 public joinsChecked;
    mapping(address => uint256) public tumblerSlot; // slot + 1; 0: no tumbler
    /// @notice The tokens a wallet keeps to keep its tumbler (0 without one).
    mapping(address => uint256) public keepAtLeast;
    uint256 public liveTumblers;

    event TumblerGained(address indexed wallet, uint256 slot, uint256 keepAtLeast);
    event TumblerLost(address indexed wallet, uint256 slot);
    event Collected(uint256 amount, uint256 toOperations);
    event RaceStarted(uint256 indexed id, uint256 drawBlock, uint256 slots, uint256 pot);
    event RaceWon(uint256 indexed id, address indexed winner, uint256 slot, uint256 prize, bytes32 seed); // seed: the draw block's RANDAO value
    event RaceVoid(uint256 indexed id, uint8 reason); // 1 the draw block's hash is gone, 2 no tumbler qualified, 3 the winner refused ETH
    event RaceSkipped(uint256 at, uint256 slots, uint256 pot); // nothing to race for, or nobody to race
    event OperationsPaid(address indexed operations, uint256 amount);

    error InvalidAddress();
    error WrongPool();
    error NotAWallet();
    error AlreadyRacing();
    error NotRacing();
    error PoolNotReady();
    error NotEnoughTokens(uint256 balance, uint256 needed);
    error NothingToPay();
    error TransferFailed();
    error BadHeader();

    constructor(IProtectedHook hook_, address operations_) {
        if (address(hook_) == address(0) || operations_ == address(0)) revert InvalidAddress();
        PoolKey memory key = hook_.poolKey();
        address token_ = hook_.token();
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token_ || address(key.hooks) != address(hook_)) revert WrongPool();
        hook = hook_;
        token = IERC20(token_);
        vault = ICreatorVault(hook_.feeVault());
        poolId = key.toId();
        operations = operations_;
        nextRaceAt = block.timestamp + RACE_EVERY; // deployed at the launch: the first race 15 minutes in
    }

    receive() external payable {}

    // ───────────── Tumblers ─────────────

    /// @notice Join the race with this wallet: it needs at least minimumToJoin() tokens, and keeps racing while it
    ///         holds that many. It runs from the next race that starts, if it still holds them at that start.
    function join() external {
        if (!_isWallet(msg.sender)) revert NotAWallet();
        if (tumblerSlot[msg.sender] != 0) revert AlreadyRacing();
        uint256 keep = _tokensFor(JOIN_VALUE);
        if (keep == 0) revert PoolNotReady();
        uint256 balance = token.balanceOf(msg.sender);
        if (balance < keep) revert NotEnoughTokens(balance, keep);
        uint256 slot;
        uint256 empty = _emptySlots.length;
        if (empty != 0) {
            slot = _emptySlots[empty - 1];
            _emptySlots.pop();
            _tumblers[slot] = Tumbler(msg.sender, uint48(block.timestamp), WAITING);
        } else {
            slot = _tumblers.length;
            _tumblers.push(Tumbler(msg.sender, uint48(block.timestamp), WAITING));
        }
        tumblerSlot[msg.sender] = slot + 1;
        keepAtLeast[msg.sender] = keep;
        liveTumblers++;
        _joins.push(msg.sender);
        emit TumblerGained(msg.sender, slot, keep);
    }

    /// @notice Take this wallet's tumbler out of the race.
    function leave() external {
        if (tumblerSlot[msg.sender] == 0) revert NotRacing();
        _lose(msg.sender);
    }

    /// @notice Take out the tumblers of wallets that no longer hold their keepAtLeast. Anyone may call; wallets that
    ///         still hold the line are left alone. The keeper does this as soon as it sees one.
    function prune(address[] calldata wallets) public {
        for (uint256 i; i < wallets.length; i++) {
            address w = wallets[i];
            if (tumblerSlot[w] != 0 && token.balanceOf(w) < keepAtLeast[w]) _lose(w);
        }
    }

    /// @notice The tokens a wallet needs to join now: what JOIN_VALUE buys at the pool's price.
    function minimumToJoin() external view returns (uint256) {
        return _tokensFor(JOIN_VALUE);
    }

    /// @notice Whether a wallet is in the race and still holds its line.
    function isRacing(address wallet) external view returns (bool) {
        return tumblerSlot[wallet] != 0 && token.balanceOf(wallet) >= keepAtLeast[wallet];
    }

    /// @notice Number of tumbler slots, empty ones included. Slots only ever grow.
    function tumblerSlots() external view returns (uint256) {
        return _tumblers.length;
    }

    /// @notice A slot's tumbler: its wallet (0 when empty), when it joined, and the first race it runs in (WAITING until
    ///         the next start checks it in).
    function tumblerAt(uint256 slot) external view returns (address owner, uint48 since, uint48 fromRace) {
        Tumbler memory t = _tumblers[slot];
        return (t.owner, t.since, t.fromRace);
    }

    /// @notice Joins the next start will check (at most MAX_JOIN_CHECKS of them).
    function joinsWaiting() external view returns (uint256) {
        return _joins.length - joinsChecked;
    }

    /// @notice Up to `count` slots from `start`, for the website and the keeper.
    function tumblersPage(uint256 start, uint256 count) external view returns (Tumbler[] memory page) {
        uint256 end = Math.min(start + count, _tumblers.length);
        page = new Tumbler[](end > start ? end - start : 0);
        for (uint256 i = start; i < end; i++) page[i - start] = _tumblers[i];
    }

    /// @notice The draw as a view: slot numbers from `seed` (keccak256(seed, i) for i = 0, 1, ...) among the first
    ///         `slots` slots, until one holds a tumbler that runs in race `id` and holds its line; at most `tries`
    ///         numbers. (0, 0) if none.
    function drawTumbler(bytes32 seed, uint256 slots, uint256 id, uint256 tries) external view returns (address owner, uint256 slot) {
        if (slots == 0 || slots > _tumblers.length) return (address(0), 0);
        for (uint256 i; i < tries; i++) {
            slot = uint256(keccak256(abi.encode(seed, i))) % slots;
            Tumbler memory t = _tumblers[slot];
            if (_qualifies(t, id)) return (t.owner, slot);
        }
        return (address(0), 0);
    }

    // ───────────── The race ─────────────

    /// @notice The pot: everything here except the operations share (fees not yet booked count once they are).
    function pot() public view returns (uint256) {
        uint256 fresh = address(this).balance - booked;
        return booked + fresh - operationsOwed - fresh * OPERATIONS_SHARE / CREATOR_SHARE;
    }

    /// @notice The next race's prize at the current pot and price.
    function nextPrize() external view returns (uint256) {
        uint256 fresh = _feedPrice();
        uint256 potNow = pot();
        return Math.min(potNow, _maxPrize(potNow, fresh != 0 ? fresh : lastPrice));
    }

    /// @notice A block's RANDAO value (the draw's seed) from its RLP header, for anyone to check a race's draw with.
    function seedOf(bytes calldata header) external pure returns (bytes32) {
        return _randaoOf(header);
    }

    /// @notice Collect the fees, prune the wallets given, finish the race whose draw block has passed, start the next
    ///         one when it is due. Anyone may call; the caller pays its own gas.
    /// @param drawHeader the RLP header of the waiting race's draw block, when that block has passed (else empty)
    /// @param underwater wallets that fell below their keepAtLeast, to take out before the next race starts
    /// @return acted whether a race finished or started (or was skipped)
    function race(bytes calldata drawHeader, address[] calldata underwater) external nonReentrant returns (bool acted) {
        _collect();
        prune(underwater);
        Pending memory p = pending;
        if (p.id != 0 && block.number > p.drawBlock) {
            delete pending;
            _finish(p, drawHeader);
            acted = true;
        }
        if (pending.id == 0 && block.timestamp >= nextRaceAt) {
            _start();
            acted = true;
        }
    }

    /// @notice Pays the operations share to the operations wallet, the only place it can go. Anyone may call.
    function withdrawOperations() external nonReentrant {
        _collect();
        uint256 amount = operationsOwed;
        if (amount == 0) revert NothingToPay();
        operationsOwed = 0;
        booked -= amount;
        (bool ok,) = operations.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit OperationsPaid(operations, amount);
    }

    // ───────────── Inside ─────────────

    function _lose(address owner) private {
        uint256 s = tumblerSlot[owner];
        delete tumblerSlot[owner];
        delete keepAtLeast[owner];
        delete _tumblers[s - 1];
        _emptySlots.push(s - 1);
        liveTumblers--;
        emit TumblerLost(owner, s - 1);
    }

    /// @dev A tumbler checked in by race `id`'s start or an earlier one, whose wallet holds its line.
    function _qualifies(Tumbler memory t, uint256 id) private view returns (bool) {
        return t.owner != address(0) && t.fromRace <= id && token.balanceOf(t.owner) >= keepAtLeast[t.owner];
    }

    /// @dev Moves the creator fees from the vault here when this contract is their recipient, then splits whatever
    ///      arrived since the last split.
    function _collect() private {
        if (vault.creatorRecipient() == address(this) && vault.creatorAccrued() != 0) vault.claimCreator();
        uint256 fresh = address(this).balance - booked;
        if (fresh == 0) return;
        uint256 toOperations = fresh * OPERATIONS_SHARE / CREATOR_SHARE;
        operationsOwed += toOperations;
        booked += fresh;
        emit Collected(fresh, toOperations);
    }

    function _start() private {
        uint256 potNow = booked - operationsOwed;
        nextRaceAt = block.timestamp + RACE_EVERY;
        uint256 id = races + 1;
        if (potNow >= MIN_POT) _checkJoins(id);
        uint256 slots = _tumblers.length;
        if (liveTumblers == 0 || potNow < MIN_POT) {
            emit RaceSkipped(block.timestamp, slots, potNow);
            return;
        }
        races = id;
        pending = Pending(uint64(id), uint64(block.number + DRAW_DELAY), uint64(block.timestamp), uint64(slots));
        emit RaceStarted(id, block.number + DRAW_DELAY, slots, potNow);
    }

    /// @dev The start's check of the wallets that joined since the last start, in the start's own transaction: one that
    ///      holds its line runs from race `id` on, one that does not loses its tumbler. Tokens passed from wallet to
    ///      wallet before the start sit in one of them now, so they pass for one tumbler. At most MAX_JOIN_CHECKS
    ///      joins; the rest wait for the next start.
    function _checkJoins(uint256 id) private {
        uint256 at = joinsChecked;
        uint256 end = Math.min(_joins.length, at + MAX_JOIN_CHECKS);
        for (; at < end; at++) {
            address wallet = _joins[at];
            uint256 s = tumblerSlot[wallet];
            if (s == 0 || _tumblers[s - 1].fromRace != WAITING) continue; // left or pruned since, or checked in already
            if (token.balanceOf(wallet) >= keepAtLeast[wallet]) _tumblers[s - 1].fromRace = uint48(id);
            else _lose(wallet);
        }
        joinsChecked = at;
    }

    function _finish(Pending memory p, bytes calldata drawHeader) private {
        bytes32 hash = _blockHash(p.drawBlock);
        if (hash == bytes32(0)) {
            emit RaceVoid(p.id, 1);
            return;
        }
        if (keccak256(drawHeader) != hash) revert BadHeader();
        bytes32 seed = _randaoOf(drawHeader);
        (address winner, uint256 slot) = _draw(seed, p.slots, p.id);
        if (winner == address(0)) {
            emit RaceVoid(p.id, 2);
            return;
        }
        uint256 potNow = booked - operationsOwed;
        uint256 prize = Math.min(potNow, _maxPrize(potNow, _price()));
        booked -= prize;
        (bool ok,) = winner.call{value: prize, gas: 30_000}("");
        if (!ok) {
            booked += prize;
            emit RaceVoid(p.id, 3);
            return;
        }
        paidToWinners += prize;
        emit RaceWon(p.id, winner, slot, prize, seed);
    }

    /// @dev The draw at the finish: like drawTumbler, and a drawn wallet that no longer holds its line loses its
    ///      tumbler on the spot.
    function _draw(bytes32 seed, uint256 slots, uint256 id) private returns (address, uint256) {
        if (slots == 0 || slots > _tumblers.length) return (address(0), 0);
        for (uint256 i; i < MAX_TRIES; i++) {
            uint256 slot = uint256(keccak256(abi.encode(seed, i))) % slots;
            Tumbler memory t = _tumblers[slot];
            if (t.owner == address(0) || t.fromRace > id) continue;
            if (token.balanceOf(t.owner) < keepAtLeast[t.owner]) {
                _lose(t.owner);
                continue;
            }
            return (t.owner, slot);
        }
        return (address(0), 0);
    }

    /// @dev How many tokens `eth` is worth at the pool's current price (rounded down); 0 before the pool exists.
    function _tokensFor(uint256 eth) private view returns (uint256) {
        (uint160 sqrtPrice,,,) = POOL_MANAGER.getSlot0(poolId);
        if (sqrtPrice == 0) return 0;
        return Math.mulDiv(Math.mulDiv(eth, sqrtPrice, 1 << 96), sqrtPrice, 1 << 96);
    }

    /// @dev A wallet: no code, or an EIP-7702 delegation (0xef0100 followed by an address).
    function _isWallet(address account) private view returns (bool) {
        uint256 size = account.code.length;
        if (size == 0) return true;
        return size == 23 && bytes3(account.code) == 0xef0100;
    }

    /// @dev The prize cap in ETH for a pot of `potEth` at the given ETH/USD price: PRIZE_STEP_USD for every full
    ///      POT_STEP_USD in the pot ($100 at $1,000, $200 at $2,000, ...), at least one step and at most
    ///      MAX_PRIZE_STEPS; FALLBACK_MAX_PRIZE without a price.
    function _maxPrize(uint256 potEth, uint256 price) private pure returns (uint256) {
        if (price == 0) return FALLBACK_MAX_PRIZE;
        uint256 steps = potEth * price / 1e18 / POT_STEP_USD; // full $500s in the pot
        steps = Math.max(1, Math.min(steps, MAX_PRIZE_STEPS));
        return steps * PRIZE_STEP_USD * 1e18 / price;
    }

    /// @dev ETH/USD for a payout: Chainlink's fresh answer (kept as lastPrice), else the last fresh one.
    function _price() private returns (uint256) {
        uint256 fresh = _feedPrice();
        if (fresh == 0) return lastPrice;
        lastPrice = fresh;
        return fresh;
    }

    /// @dev Chainlink's ETH/USD when it answers with a positive price at most PRICE_MAX_AGE old, else 0.
    function _feedPrice() private view returns (uint256) {
        try ETH_USD.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer > 0 && updatedAt + PRICE_MAX_AGE >= block.timestamp) return uint256(answer);
        } catch {}
        return 0;
    }

    /// @dev A block's RANDAO value from its RLP header: the header's 14th field, mixHash (prevRandao since the merge),
    ///      a 32-byte string after parentHash ... extraData. The fields before it are skipped item by item.
    function _randaoOf(bytes calldata header) private pure returns (bytes32) {
        if (header.length < 2 || uint8(header[0]) < 0xf8) revert BadHeader(); // a long list
        uint256 lengthBytes = uint8(header[0]) - 0xf7;
        uint256 at = 1 + lengthBytes;
        if (at + _bigEndian(header, 1, lengthBytes) != header.length) revert BadHeader();
        for (uint256 field; field < 13; field++) at = _skipItem(header, at);
        if (at + 33 > header.length || uint8(header[at]) != 0xa0) revert BadHeader();
        return bytes32(header[at + 1:at + 33]);
    }

    /// @dev Where the RLP item at `at` ends.
    function _skipItem(bytes calldata data, uint256 at) private pure returns (uint256 next) {
        if (at >= data.length) revert BadHeader();
        uint256 prefix = uint8(data[at]);
        if (prefix < 0x80) next = at + 1;
        else if (prefix < 0xb8) next = at + 1 + prefix - 0x80;
        else if (prefix < 0xc0) next = at + 1 + prefix - 0xb7 + _bigEndian(data, at + 1, prefix - 0xb7);
        else if (prefix < 0xf8) next = at + 1 + prefix - 0xc0;
        else next = at + 1 + prefix - 0xf7 + _bigEndian(data, at + 1, prefix - 0xf7);
        if (next > data.length) revert BadHeader();
    }

    function _bigEndian(bytes calldata data, uint256 at, uint256 length) private pure returns (uint256 value) {
        if (length > 4 || at + length > data.length) revert BadHeader();
        for (uint256 i; i < length; i++) value = (value << 8) | uint8(data[at + i]);
    }

    /// @dev The hash of block `n`: from the chain for the last 256 blocks, from the EIP-2935 history contract up to
    ///      8191 blocks back; 0 when it is gone.
    function _blockHash(uint256 n) private view returns (bytes32 h) {
        if (n >= block.number) return bytes32(0);
        uint256 age = block.number - n;
        if (age <= 256) return blockhash(n);
        if (age > 8191) return bytes32(0);
        (bool ok, bytes memory out) = BLOCK_HASH_HISTORY.staticcall(abi.encode(n));
        if (ok && out.length == 32) h = abi.decode(out, (bytes32));
    }
}
