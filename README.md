# TUMBLE ($TUMBLE)

Exact sources submitted to the Programmable Custom Launch API (Ethereum mainnet).

TUMBLE is a marble race on Ethereum. One buy of 0.01 ETH or more puts your tumbler in a race every 15 minutes. The winner is drawn on chain from Ethereum's RANDAO and paid at once from a pot that 2% of every trade fills.

## The launch

The launch is Programmable's protected launch package, unchanged. `src/` and `lib/` hold the exact sources their builder writes, and `protection/` holds the compiler input and the artifacts.

- `ProtectedLaunchTokenV1` is the token: a fixed-supply ERC-20 with the launch window's receiving limit of 2% per wallet for the first 5 minutes.
- `ProtectedNativeInitializerV1` creates the ETH pool at a valuation of at least USD 15,000, locks the whole supply in it for good and makes the launch buy for the launch wallet.
- `ProtectedNative30HookV1` is the pool's hook. Every swap pays 3% of its gross ETH side, Programmable's 0.3% and 2.7% for the creator. For the first 30 seconds after the launch the buy fee starts at 99% and falls to 3%, and that extra part goes to Programmable's treasury. The creator fees accrue in the hook's fee vault and are paid to the launch wallet.

## The game

`game/TumbleRace.sol` is the race contract. It is not part of the launch graph. The game server deploys it right after the launch and the website publishes its address.

- The launch wallet forwards the creator fees to the race contract every 10 minutes. The contract keeps 20/27 of what arrives (2% of every trade) as the prize pool and pays 7/27 (0.7%) to the operations wallet, which is fixed at deployment and pays the gas of every race.
- A wallet joins the race with `join()`. It needs at least `minimumToJoin()` tokens, what 0.0095 ETH buys at the pool's price, and that amount is remembered as the wallet's line. The tumbler runs in every race that starts 5 minutes or more after joining, while the wallet holds its line. Anyone may `prune()` wallets that fell below their line, the keeper does so before every race, and the drawn winner must hold the line at the payout. `leave()` takes a tumbler out.
- A race every 15 minutes. The winner is drawn among the tumblers from the RANDAO value of the block 5 blocks after the start, read from that block's RLP header and checked against its hash. The prize is paid at once. It grows with the pool by USD 50 for every full USD 500 (Chainlink ETH/USD), from USD 50 to USD 1,000.
- The contract has no owner and nothing to change.
