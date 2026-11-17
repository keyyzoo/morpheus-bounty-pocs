# Morpheus Bug Bounty — Fork PoCs

Proof-of-concept Foundry tests for two findings submitted to the Morpheus Bug
Bounty Program (mor.org/bug-bounty, v2). Both tests run against mainnet forks
at pinned blocks, use unprivileged attackers only, and assert the loss
directly. Nothing here touches mainnet state.

## Findings

- **PoC A — Fake yield donation steals other stakers' MOR** (`test/PocA.t.sol`).
  `DistributorV2.distributeRewards()` measures yield as the raw `balanceOf`
  delta of the yield token. Donating aWBTC straight to the Distributor makes
  the next public `distributeRewards()` count the donation as yield, inflating
  that pool's share of the fixed daily MOR emission. Fork: Ethereum mainnet,
  block 26432684. Attacker nets **+$408.02 per daily window** (gain 1,198.38
  MOR / $835.27 minus a $427.25 donation), victim stETH pool −1,238.00 MOR.
- **PoC B — Provider approval is a bearer token** (`test/PocB.t.sol`).
  `SessionRouter._extractProviderApproval` decodes the signed user address and
  discards it; the `SessionApprovedForAnotherUser` error is declared and never
  used. Anyone seeing a live approval + signature within its 10-minute TTL can
  front-run the intended user and open a session as themselves, burning the
  victim's approval. Fork: Base, block 58513216. Provider **+0.6048 MOR**
  exactly; fundingAccount **−0.6048 MOR** exactly; attacker fully refunded.

## Run

Requires [Foundry](https://book.getfoundry.sh/) (`forge` 1.7.1 used here;
`FOUNDRY_VIA_IR=false`). No setup beyond an RPC URL — the fork RPCs are
public endpoints hardcoded in the tests, and `forge-std` is vendored in `lib/`.

```shell
forge test --match-contract "PocA|PocB" -vv
```

Expected: **2 passed, 0 failed.**

## Notes

- PoC A mocks `ChainLinkDataConsumer.getChainLinkDataFeedLatestAnswer` to
  return the pinned-block price, emulating oracle liveness only: Chainlink
  feeds are frozen on a fork and the 3600s price-update delay would otherwise
  revert after the 86400s warp to the distribution gate. The mock does not
  touch Distributor/DepositPool accounting, and the identical mock in the
  no-donation control run gains ~0 MOR, so it cannot manufacture the result.
- PoC B's provider key (`0xBEEF…`) is a throwaway test key. No real keys,
  no privileged accounts, no mainnet execution anywhere in this repo.
- Full write-up: `POC-REPORT.md`.
