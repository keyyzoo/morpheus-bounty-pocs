# Morpheus Bug Bounty — Phase 3 Fork PoCs (record)

- Project: `~/workspace/mor-bounty/poc/` (Foundry, forge 1.7.1, `FOUNDRY_VIA_IR=false`, optimizer on)
- Tests: `test/PocA.t.sol` (Lead 1, fake-yield donation), `test/PocB.t.sol` (C1, bearer approval)
- Run: `forge test --match-contract "PocA|PocB" -vv` → **2 passed, 0 failed**
- Forks only. No mainnet execution, no privileged accounts, no real keys
  (PoC B provider key is a throwaway test key). Nothing submitted or published.

## PoC A — PASS (Lead 1 PROVEN)

- Fork: Ethereum, block **26432684** (T5's block; window was profitable, no re-pin needed).
- Measured window: R = 2,856.359676 MOR ($1,990.88 @ $0.697/MOR, re-verified
  2026-11-17: MEXC $0.696973, CoinCodex $0.6961, CoinGecko $0.700018);
  Y (natural yield, all 5 pools) = **$447.37**; attacker share of wBTC pool s = 0.858871.
- Donation: 664,639 sats aWBTC = **$427.25** (D* per formula; aWBTC minted by
  supplying wBTC to Aave on the fork, address read from Distributor state).
- Attack pending (window 1) = 1,198.432747 MOR; control (same stake, no donation)
  = 0.049351 MOR. Gain = 1,198.383395 MOR = **$835.27**.
- **Net profit = $835.27 − $427.25 = $408.02 per daily window.**
  Cross-check: (sqrt(R·s) − sqrt(Y))² = (sqrt(1709.90) − sqrt(447.37))² ≈ $408.04. ✓
- Victims: stETH pool's credit 1,237,385.625 → 1,236,147.625 MOR (**−1,238.00 MOR**,
  −$862.89); wBTC pool 1.382 → 1,396.68 MOR (+1,395.30, of which the attacker
  takes 1,198.38 and pre-existing wBTC stakers ~196.92).
- Claim works (LayerZero send on fork with 0.1 ETH value, pending → 0);
  5 wBTC principal fully returned (500,000,000 sats) in both runs.
- Disclosed fork limitation: Chainlink feeds are frozen on a fork and the stETH
  feed's allowedPriceUpdateDelay is only 3600s, so any warp to the 86400s gate
  makes `updateDepositTokensPrices` revert ("DR: price for pair is zero"). The PoC
  mocks `ChainLinkDataConsumer.getChainLinkDataFeedLatestAnswer` to return the
  actual pinned-block price per path — emulating oracle liveness only. It does not
  touch Distributor/DepositPool accounting, and the control run had the identical
  mock yet gained ~0, so the mock cannot manufacture the result.

## PoC B — PASS (C1 PROVEN)

- Fork: Base, block **58513216**, ts 1794893018.
- Re-read at pinned block: getComputeBalance = 3,010,721.843 MOR;
  totalMORSupply = 10,304,975.102 MOR; stipend for 10,000 MOR = 29.216197 MOR;
  bidFee = 0.3 MOR. Duration capped at 604,800 s as spec'd.
- Attacker opens a session AS THEMSELVES with the victim-only approval
  (abi.encode(bidId, 8453, V, ts), eth-signed keccak256, vm.sign with fresh
  PoC-controlled provider key); approval marked used; session user == attacker.
- Victim's identical call reverts `SessionDuplicateApproval`; victim has 0 sessions.
- Settlement (late close, provider-signed receipt): provider 0.6 → **1.2048 MOR**
  (+0.6048 exactly); fundingAccount 85,131.140319 → 85,130.535519 MOR (**−0.6048
  exactly**); `claimForProvider` after close pays 0 extra.
- Attacker: 10,000 → 9,993.356965 MOR immediately after close (6.643035 MOR
  day-locked on hold), → **exactly 10,000 MOR** after `withdrawUserStakes` past
  the day boundary. Correction to the T4 spec: the refund is NOT immediate in
  full — ~6.64 MOR is locked until the next day boundary; final refund is exact.
- Impact: per stolen approval, up to 0.6048 MOR of unauthorized emission spend
  (fundingAccount → provider) at this price/stake; attacker pays gas only and is
  fully refunded. Scales linearly in harvested approvals (T4's 6,048 MOR max per
  approval at max price/stake stands, not re-proven here).

## Verdicts

- Lead 1 (fake yield donation): **PROVEN** — net +$408.02/window at the pinned
  block, repeatable each daily window, victim loss measured on-chain in MOR.
- C1 (bearer approval): **PROVEN** — exact 0.6048 MOR unauthorized flow,
  victim DoS confirmed. Severity stays Medium at best (attacker gains service,
  not MOR; the MOR goes to the provider, the intended emission recipient).
