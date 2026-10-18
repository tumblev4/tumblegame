# TUMBLE ($TUMBLE)

Exact sources submitted to the Programmable Custom Launch API (Ethereum mainnet).

TUMBLE is a marble race on Ethereum. Buy $TUMBLE for 0.01 ETH or more, join once, and your tumbler runs in a race every 15 minutes while you hold. The winner is drawn on chain from Ethereum's RANDAO and paid in ETH from a pot that 2% of every trade fills.

Website https://tumblegame.xyz/ and X https://x.com/tumblegamev4.

## The launch

The launch is Programmable's protected launch package. `src/launch-protection`, `src/ethereum-native30-v3` and `lib/` hold the exact sources their builder writes, and `protection/` holds their compiler input and artifacts, unchanged.

- `TumbleToken` (`src/TumbleToken.sol`) is the token. It is `ProtectedLaunchTokenV1`, unchanged, plus read-only project details for explorers and wallets. It has the same `description()`, `website()`, `image()`, `extraData()` and `metadata()` getters as Programmable's standard tokens, and every value is a constant. It adds no state, no owner and no code on the transfer path. Like its parent, it is a fixed-supply ERC-20 with the launch window's receiving limit of 2% per wallet for the first 5 minutes. Its own compiler input is `token/standard-json.json`, with the package's exact settings (solc 0.8.26, via IR, optimizer 200, Cancun, no metadata hash). The other sources in it are byte-identical to the package, and `ProtectedLaunchTokenV1` compiled there matches the package's artifact byte for byte.
- `ProtectedNativeInitializerV1` creates the ETH pool at a valuation of at least USD 15,000, locks the whole supply in it for good and makes the launch buy for the launch wallet. The launch wallet burns those tokens right after the launch, so the launcher keeps none.
- Six team wallets and the launch wallet are exempt from the extra opening fee of the first 30 seconds, as Programmable's package allows. They stay under the 2% limit like everyone else.
- `ProtectedNative30HookV1` is the pool's hook. Every swap pays 3% of its gross ETH side, Programmable's 0.3% and 2.7% for the creator. For the first 30 seconds after the launch the buy fee starts at 99% and falls to 3%, and that extra part goes to Programmable's treasury. The creator fees accrue in the hook's fee vault and are paid to the launch wallet.

## The game

`game/TumbleRace.sol` is the race contract. It is not part of the launch graph. The game server deploys it right after the launch and the website publishes its address.

- The game server claims the creator fees for the launch wallet and forwards them to the race contract every 10 minutes. It forwards only those fees, never other money on the wallet. The contract keeps 20/27 of what arrives (2% of every trade) as the prize pool and pays 7/27 (0.7%) to the operations wallet. That wallet is fixed at deployment and funds the keeper, which pays the gas of every race.
- A wallet joins with `join()`. It needs at least `minimumToJoin()` tokens, what 0.0095 ETH buys at the pool's price, and that amount is remembered as the wallet's line. The next race start checks every wallet that joined since the previous start. A wallet that still holds its line runs in that race and in every race after it, while it holds the line. A wallet that does not loses its tumbler. A start checks at most 500 new joins, and the rest are checked by the next one.
- Anyone may `prune()` wallets that fell below their line, and the keeper does so all the time. The drawn winner must still hold the line at the payout. `leave()` takes a tumbler out.
- A race every 15 minutes. The winner is drawn among the tumblers from the RANDAO value of the block 5 blocks after the start, read from that block's RLP header and checked against its hash. The prize is paid at once in ETH. It grows with the pool by USD 50 for every full USD 500 (Chainlink ETH/USD), from USD 50 to USD 1,000.
- The contract has no owner and nothing to change.
