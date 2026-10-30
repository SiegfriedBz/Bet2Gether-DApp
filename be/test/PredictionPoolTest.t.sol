// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {
    PredictionPool,

    // errors
    PredictionPool_InvalidValue,
    PredictionPool_InvalidFeed,
    PredictionPool_InvalidDuration,
    PredictionPool_RoundIsNotActive,
    PredictionPool_CanBetOnlyOncePerRound,
    PredictionPool_ZeroAddressNotAllowed,
    PredictionPool_NotAWinner,
    PredictionPool_RoundNotResolved,
    PredictionPool_AlreadyClaimed,
    PredictionPool_InvalidFeed,
    PredictionPool_InvalidChainlinkDecimals,
    PredictionPool_NegativeChainlinkPrice
} from "../src/PredictionPool.sol";
import {PredictionPoolScript} from "../script/PredictionPoolScript.s.sol";
import {Constants_PredictionPool} from "../script/Constants_PredictionPool.sol";
import {MockOffchainAggregator} from "./mocks/price-feeds/MockOffchainAggregator.sol";

contract PredictionPoolTest is Test, Constants_PredictionPool {
    PredictionPool public pPool;
    MockOffchainAggregator public mockPriceFeed;

    address owner = vm.envAddress("MY_ADDRESS");
    address player01 = makeAddr("player01");
    address player02 = makeAddr("player02");
    uint256 betValue = 0.1 ether;
    uint256 betOnValue = betValue / 2;
    uint256 zeroBet = 0;
    address zeroAddress = address(0);

    function setUp() public {
        // 1. deploy PredictionPoolScript (PredictionPool deployer)
        PredictionPoolScript predictionPoolDeployer = new PredictionPoolScript();
        // 2. deploy PredictionPool
        pPool = predictionPoolDeployer.run();

        // 3. deploy MockOffchainAggregator (Chainlink Price Feeds)
        // constructor(uint8 _decimals, int256 _initialAnswer)
        mockPriceFeed = new MockOffchainAggregator(18, 1_000);
    }

    // === deployment Tests ===
    function test_deployment() public view {
        // happy path
        assertEq(pPool.owner(), owner);
        assertEq(pPool.minRoundDuration(), MIN_ROUND_DURATION);
        assertEq(pPool.allowedDataFeeds(SEPOLIA_LINK_USD), true);
        assertEq(pPool.allowedDataFeeds(SEPOLIA_ETH_USD), true);
        assertEq(pPool.allowedDataFeeds(SEPOLIA_BTC_USD), true);
        assertEq(pPool.allowedDataFeeds(SEPOLIA_DAI_USD), true);

        // "un-happy" path
        assertEq(pPool.allowedDataFeeds(0xC59e3633BAAc79493d908E63626716E204a45eAa), false);
    }

    // === getRound Tests ===
    function test_getRound() public {
        uint256 timestamp = block.timestamp;

        address feed = SEPOLIA_LINK_USD;
        uint256 target = uint256(1_000);
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);
        pPool.createRound{value: betValue}(feed, target, PredictionPool.BetSide.Gte, duration);

        PredictionPool.Round memory round = pPool.getRound(0);

        assertEq(round.creator, player01);
        assertEq(round.priceFeed, feed);
        assertEq(round.target, target);
        assertEq(round.gteTotal, betValue);
        assertEq(round.ltTotal, 0);
        assertEq(uint8(round.status), uint8(PredictionPool.RoundStatus.Active));
        assertEq(round.end, timestamp + duration);
    }

    function test_getRound_ReturnsDefaultRound_IfNotExist() public {
        address feed = SEPOLIA_LINK_USD;
        uint256 target = uint256(1_000);
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);
        pPool.createRound{value: betValue}(feed, target, PredictionPool.BetSide.Gte, duration);

        PredictionPool.Round memory round = pPool.getRound(1);

        assertEq(round.creator, zeroAddress);
        assertEq(round.priceFeed, zeroAddress);
        assertEq(round.target, 0);
        assertEq(round.gteTotal, 0);
        assertEq(round.ltTotal, 0);
        assertEq(uint8(round.status), uint8(PredictionPool.RoundStatus.NotStarted));
        assertEq(round.end, 0);
    }

    // === createRound Tests ===
    function test_createRound() public {
        uint256 timestamp = block.timestamp;

        (PredictionPool.Round memory round, address feed, uint256 target, uint256 duration) = _player01CreateRound();

        assertEq(round.creator, player01);
        assertEq(round.priceFeed, feed);
        assertEq(round.target, target);
        assertEq(round.gteTotal, betValue);
        assertEq(round.ltTotal, 0);
        assertEq(uint8(round.status), uint8(PredictionPool.RoundStatus.Active));
        assertEq(round.end, timestamp + duration);
    }

    function test_createRound_Emits_RoundCreated_Event() public {
        address feed = SEPOLIA_LINK_USD;
        uint256 target = 1_000;
        uint256 duration = 2 minutes;

        hoax(player01);

        vm.expectEmit();
        emit PredictionPool.PredictionPool_RoundCreated(
            0, player01, betValue, PredictionPool.BetSide.Gte, block.timestamp + duration
        );

        pPool.createRound{value: betValue}(feed, target, PredictionPool.BetSide.Gte, duration);
    }

    function test_createRound_Emits_NewBet_Event() public {
        address feed = SEPOLIA_LINK_USD;
        uint256 target = 1_000;
        uint256 duration = 2 minutes;

        hoax(player01);

        vm.expectEmit();
        emit PredictionPool.PredictionPool_NewBet(0, player01, betValue, PredictionPool.BetSide.Gte, block.timestamp);

        pPool.createRound{value: betValue}(feed, target, PredictionPool.BetSide.Gte, duration);
    }

    function test_createRound_RevertWhen_OutOfFunds() public {
        address feed = SEPOLIA_LINK_USD;
        uint256 target = uint256(1_000);
        uint256 duration = 2 minutes;

        // Ensure the sender has no funds
        vm.prank(player01);
        vm.deal(player01, 0);

        // Use try/catch to check for OutOfFunds
        bool reverted = false;
        try pPool.createRound{value: betValue}(feed, target, PredictionPool.BetSide.Gte, duration) {
            // If this block executes, the call did not revert
            assertFalse(true, "Expected OutOfFunds but call succeeded");
        } catch Error(string memory reason) {
            // Check if the error is OutOfFunds
            assertTrue(keccak256(bytes(reason)) == keccak256(bytes("OutOfFunds")), "Expected OutOfFunds");
            reverted = true;
        } catch {
            // Catch any other low-level error (e.g., OutOfFunds)
            reverted = true;
        }

        assertTrue(reverted, "Expected OutOfFunds but call succeeded");
    }

    function test_createRound_RevertWhen_BetValueIsZero() public {
        address feed = SEPOLIA_LINK_USD;
        uint256 target = uint256(1_000);
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);

        vm.expectRevert(PredictionPool_InvalidValue.selector);
        pPool.createRound{value: zeroBet}(feed, target, PredictionPool.BetSide.Gte, duration);
    }

    function test_createRound_RevertWhen_InvalidFeed() public {
        address invalidFeed = zeroAddress;
        uint256 target = uint256(1_000);
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);

        vm.expectRevert(PredictionPool_InvalidFeed.selector);
        pPool.createRound{value: betValue}(invalidFeed, target, PredictionPool.BetSide.Gte, duration);
    }

    function test_createRound_RevertWhen_InvalidDuration() public {
        uint256 invalidDuration = 10 seconds; // 15 seconds
        address feed = SEPOLIA_LINK_USD;
        uint256 target = uint256(1_000);

        // hoax => prank & fund
        hoax(player01);

        vm.expectRevert(PredictionPool_InvalidDuration.selector);
        pPool.createRound{value: betValue}(feed, target, PredictionPool.BetSide.Gte, invalidDuration);
    }

    // === betOn Tests ===
    function test_betOn() public {
        // 1. player01 creates new round
        (PredictionPool.Round memory round,,,) = _player01CreateRound();

        // 2. player02 bets on round
        hoax(player02);
        pPool.betOn{value: betOnValue}(round.id, PredictionPool.BetSide.Lt);

        // 3. fetch round
        PredictionPool.Round memory updatedRound = pPool.getRound(round.id);

        assertEq(updatedRound.gteTotal, betValue);
        assertEq(updatedRound.ltTotal, betOnValue);
    }

    function test_betOn_Emits_NewBet_Event() public {
        // 1. player01 creates new round
        (PredictionPool.Round memory round,,,) = _player01CreateRound();

        // 2. player02 bets on round
        hoax(player02);

        vm.expectEmit();
        emit PredictionPool.PredictionPool_NewBet(0, player02, betOnValue, PredictionPool.BetSide.Lt, block.timestamp);

        pPool.betOn{value: betOnValue}(round.id, PredictionPool.BetSide.Lt);
    }

    function test_betOn_RevertWhen_BetValueIsZero() public {
        // 1. player01 creates new round
        (PredictionPool.Round memory round,,,) = _player01CreateRound();

        // 2. player02 bets on round without sending value
        hoax(player02);

        vm.expectRevert(PredictionPool_InvalidValue.selector);
        pPool.betOn{value: zeroBet}(round.id, PredictionPool.BetSide.Lt);
    }

    function test_betOn_RevertWhen_RoundNotActive() public {
        // 1. player01 creates new round
        (PredictionPool.Round memory round,,,) = _player01CreateRound();

        // 2. Fwd Time travel - Sets block.timestamp.
        vm.warp(round.end + 1);

        // 3. player02 tries betting on non-active round
        hoax(player02);

        vm.expectRevert(PredictionPool_RoundIsNotActive.selector);
        pPool.betOn{value: betOnValue}(round.id, PredictionPool.BetSide.Lt);
    }

    function test_betOn_RevertWhen_PlayerAlreadyBetOnRound() public {
        // 1. player01 creates new round
        (PredictionPool.Round memory round,,,) = _player01CreateRound();

        // 2. player02 bets on round
        hoax(player02);
        pPool.betOn{value: betOnValue}(round.id, PredictionPool.BetSide.Lt);

        // 3. player02 tries betting again
        vm.prank(player02);
        vm.expectRevert(PredictionPool_CanBetOnlyOncePerRound.selector);
        pPool.betOn{value: betOnValue}(round.id, PredictionPool.BetSide.Lt);
    }

    // === roundIsReadyForUpkeep Tests ===
    function test_roundIsReadyForUpkeep_ReturnsTrueWhenRoundHasEndend() public {
        // 1. player01 creates new round
        (PredictionPool.Round memory round,,,) = _player01CreateRound();

        vm.warp(round.end);

        assertTrue(pPool.roundIsReadyForUpkeep(round.id));
    }

    function test_roundIsReadyForUpkeep_ReturnsFalseWhenRoundHasNotEndend() public {
        // 1. player01 creates new round
        (PredictionPool.Round memory round,,,) = _player01CreateRound();

        vm.warp(round.end - 1);

        assertFalse(pPool.roundIsReadyForUpkeep(round.id));
    }

    function test_roundIsReadyForUpkeep_ReturnsFalseWhenRoundAlreadyResolved() public {
        // 1. add mockPriceFeed to simulate price feed
        _ownerAddMockPriceFeed(address(pPool));

        // 1.1. set mockPriceFeed return value
        mockPriceFeed.updateAnswer(100);

        // 2. player01 create a round on mockPriceFeed
        address feed = address(mockPriceFeed);
        uint256 target = 10;
        PredictionPool.BetSide betSide = PredictionPool.BetSide.Gte;
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);
        pPool.createRound{value: betValue}(feed, target, betSide, duration);

        PredictionPool.Round memory round = pPool.getRound(0);

        // 3. Resolve the round (simulate Chainlink Automation calling performUpkeep - here bypassing checkUpkeep)
        vm.warp(round.end + 1);
        uint256[] memory roundIds = new uint256[](1);
        roundIds[0] = round.id;
        pPool.performUpkeep(abi.encode(roundIds));

        // 4. Assert can not perform Upkeep again on this round
        assertFalse(pPool.roundIsReadyForUpkeep(round.id));
    }

    // === resolveRound Tests ===
    /// @dev Tests _resolveRound when price equals target and player makes CORRECT price move prediction.
    function test_resolveRound_PriceEqualsTarget_WithCorrectSidePrediction() public {
        _ownerAddMockPriceFeed(address(pPool));
        mockPriceFeed.updateAnswer(100); // Price = 100

        hoax(player01);
        pPool.createRound{value: betValue}(address(mockPriceFeed), 100, PredictionPool.BetSide.Gte, 2 minutes);

        vm.warp(block.timestamp + 2 minutes + 1);

        uint256[] memory roundIds = new uint256[](1);
        roundIds[0] = 0;
        pPool.performUpkeep(abi.encode(roundIds));

        PredictionPool.Round memory round = pPool.getRound(0);

        assertEq(uint8(round.status), uint8(PredictionPool.RoundStatus.Resolved));
        assertTrue(pPool.isRoundWinner(0, player01)); // player01 should be a winner (GTE, price == target)
    }

    /// @dev Tests _resolveRound when price equals target and player makes WRONG price move prediction.
    function test_resolveRound_PriceEqualsTarget_WithWrongSidePrediction() public {
        _ownerAddMockPriceFeed(address(pPool));
        mockPriceFeed.updateAnswer(100); // Price = 100

        hoax(player01);
        pPool.createRound{value: betValue}(address(mockPriceFeed), 100, PredictionPool.BetSide.Lt, 2 minutes);

        vm.warp(block.timestamp + 2 minutes + 1);

        uint256[] memory roundIds = new uint256[](1);
        roundIds[0] = 0;
        pPool.performUpkeep(abi.encode(roundIds));

        PredictionPool.Round memory round = pPool.getRound(0);

        assertEq(uint8(round.status), uint8(PredictionPool.RoundStatus.Resolved));
        assertFalse(pPool.isRoundWinner(0, player01)); // player01 should NOT be a winner (LT, price == target)
    }

    // === claimReward Tests ===
    /// test_claimReward_When_Winner
    /// @dev Tests that a winner can claim their reward when their prediction is correct.
    ///      - Mock price feed is set to 100.
    ///      - Player predicts target = 10 and Gte (price ≥ 10), so they win because 100 ≥ 10.
    function test_claimReward_When_Winner() public {
        // 1. add mockPriceFeed to simulate price feed
        _ownerAddMockPriceFeed(address(pPool));

        // 1.1. set mockPriceFeed return value
        mockPriceFeed.updateAnswer(100);

        /**
         * 2. player01 create a round on mockPriceFeed
         * - predict target price < mockPriceFeed (=> 100)
         * - predict upside
         */
        address feed = address(mockPriceFeed);
        uint256 target = 10;
        PredictionPool.BetSide betSide = PredictionPool.BetSide.Gte;
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);
        pPool.createRound{value: betValue}(feed, target, betSide, duration);

        PredictionPool.Round memory round = pPool.getRound(0);

        // 3. Resolve the round (simulate Chainlink Automation calling performUpkeep - here bypassing checkUpkeep)
        vm.warp(round.end + 1);
        uint256[] memory roundIds = new uint256[](1);
        roundIds[0] = round.id;

        vm.expectEmit();
        emit PredictionPool.PredictionPool_RoundResolved(round.id, player01, true);
        pPool.performUpkeep(abi.encode(roundIds));

        // 3.1. Verify the Round is Resolved
        PredictionPool.Round memory resolvedRound = pPool.getRound(round.id);
        assertEq(uint8(resolvedRound.status), uint8(PredictionPool.RoundStatus.Resolved));

        // 4. Claim reward as a winner
        vm.prank(player01);
        vm.expectEmit();
        emit PredictionPool.PredictionPool_RewardClaimed(round.id, player01, betValue);
        pPool.claimReward(round.id);

        // 4.1. Verify the reward was claimed
        (,, bool claimed) = pPool.roundToPlayerBet(round.id, player01);
        assertEq(claimed, true);
    }

    /// @dev Tests that rewards are split correctly between multiple winners.
    function test_claimReward_MultipleWinners_RewardSplit() public {
        _ownerAddMockPriceFeed(address(pPool));
        mockPriceFeed.updateAnswer(100); // Price = 100

        // player01 creates a round and bets Gte (target = 10, so they win)
        hoax(player01);
        pPool.createRound{value: betValue}(address(mockPriceFeed), 10, PredictionPool.BetSide.Gte, 2 minutes);

        // player02 bets Gte (also wins)
        hoax(player02);
        pPool.betOn{value: betOnValue}(0, PredictionPool.BetSide.Gte);

        // Resolve the round
        vm.warp(block.timestamp + 2 minutes + 1);
        uint256[] memory roundIds = new uint256[](1);
        roundIds[0] = 0;
        pPool.performUpkeep(abi.encode(roundIds));

        // Calculate expected rewards
        uint256 totalPool = betValue + betOnValue;
        uint256 p1Weight = pPool.getBetWeight(0, player01);
        uint256 p2Weight = pPool.getBetWeight(0, player02);
        uint256 totalWeight = p1Weight + p2Weight;
        uint256 p1Reward = (totalPool * p1Weight) / totalWeight;
        uint256 p2Reward = (totalPool * p2Weight) / totalWeight;

        // Claim rewards
        vm.prank(player01);
        vm.expectEmit();
        emit PredictionPool.PredictionPool_RewardClaimed(0, player01, p1Reward);
        pPool.claimReward(0);

        vm.prank(player02);
        vm.expectEmit();
        emit PredictionPool.PredictionPool_RewardClaimed(0, player02, p2Reward);
        pPool.claimReward(0);
    }

    /// @dev Tests that a "last second" bet in a very long round has minimal weight and receives minimal reward.
    function test_claimReward_EdgeCase_LastSecondBet_LongDuration() public {
        uint256 sameBet = betValue;

        _ownerAddMockPriceFeed(address(pPool));
        mockPriceFeed.updateAnswer(100); // Price = 100

        // Use a very long duration (e.g., 1 year) to exaggerate the weight difference
        uint256 longDuration = 365 days;

        // player01 creates a round and bets Gte (target = 10, so they win)
        hoax(player01);
        pPool.createRound{value: sameBet}(address(mockPriceFeed), 10, PredictionPool.BetSide.Gte, longDuration);

        // Get the round's end time
        PredictionPool.Round memory round = pPool.getRound(0);
        uint256 roundEnd = round.end;

        // player02 bets Gte at the "last second" (just before round ends)
        vm.warp(roundEnd - 1); // Set block.timestamp to 1 second before round ends
        hoax(player02);
        pPool.betOn{value: sameBet}(0, PredictionPool.BetSide.Gte);

        // Resolve the round (time travel to after round ends)
        vm.warp(roundEnd + 1);
        uint256[] memory roundIds = new uint256[](1);
        roundIds[0] = 0;
        pPool.performUpkeep(abi.encode(roundIds));

        // Check the weights
        uint256 p1Weight = pPool.getBetWeight(0, player01);
        uint256 p2Weight = pPool.getBetWeight(0, player02);

        // Assert that player02's weight is extremely small (close to zero)
        // With a 1-year round, (round.end - bet.time) is just 1 second, so weight should be negligible
        assertLt(p2Weight, p1Weight / 1_000_000);

        // Calculate expected rewards
        uint256 totalPool = 2 * sameBet;
        uint256 totalWeight = p1Weight + p2Weight;
        uint256 p1Reward = (totalPool * p1Weight) / totalWeight;
        uint256 p2Reward = (totalPool * p2Weight) / totalWeight;

        // Assert that player02's reward is extremely small (close to zero)
        assertLt(p2Reward, p1Reward / 1_000_000);

        // Claim rewards
        vm.prank(player01);
        vm.expectEmit();
        emit PredictionPool.PredictionPool_RewardClaimed(0, player01, p1Reward);
        pPool.claimReward(0);

        vm.prank(player02);
        vm.expectEmit();
        emit PredictionPool.PredictionPool_RewardClaimed(0, player02, p2Reward);
        pPool.claimReward(0);
    }

    /// test_claimReward_RevertWhen_WrongPrediction
    /// Wrong Prediction 01
    /// @dev Tests that a player cannot claim a reward when their prediction is incorrect.
    ///      - Mock price feed is set to 100.
    ///      - Player predicts target = 1_000 and Gte (price ≥ 1_000), but 100 < 1_000, so they lose.
    function test_claimReward_RevertWhen_WrongPrediction() public {
        // 1. add mockPriceFeed to simulate price feed
        _ownerAddMockPriceFeed(address(pPool));

        // 1.1. set mockPriceFeed return value
        mockPriceFeed.updateAnswer(100);

        /**
         * 2. player01 create a round on mockPriceFeed
         * - predict target price > mockPriceFeed (=> 100)
         * - predict upside
         */
        address feed = address(mockPriceFeed);
        uint256 target = 1_000;
        PredictionPool.BetSide betSide = PredictionPool.BetSide.Gte;
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);
        pPool.createRound{value: betValue}(feed, target, betSide, duration);

        PredictionPool.Round memory round = pPool.getRound(0);

        // 3. Resolve the round (simulate Chainlink Automation calling performUpkeep - here bypassing checkUpkeep)
        vm.warp(round.end + 1);
        uint256[] memory roundIds = new uint256[](1);
        roundIds[0] = round.id;

        vm.expectEmit();
        emit PredictionPool.PredictionPool_RoundResolved(round.id, player01, false);
        pPool.performUpkeep(abi.encode(roundIds));

        // 3.1. Verify the Round is Resolved
        PredictionPool.Round memory resolvedRound = pPool.getRound(round.id);
        assertEq(uint8(resolvedRound.status), uint8(PredictionPool.RoundStatus.Resolved));

        // 4. Claim reward as a NOT-winner
        vm.prank(player01);
        vm.expectRevert(PredictionPool_NotAWinner.selector);
        pPool.claimReward(round.id);

        // 4.1. Verify the reward was NOT claimed
        (,, bool claimed) = pPool.roundToPlayerBet(round.id, player01);
        assertEq(claimed, false);
    }

    /// test_claimReward_RevertWhen_WrongPredictionBis
    /// Wrong Prediction 02
    /// @dev Tests that a player cannot claim a reward when their prediction is incorrect.
    ///      - Mock price feed is set to 100.
    ///      - Player predicts target = 10 and Lt (price < 10), but 10 < 1_000, so they lose.

    function test_claimReward_RevertWhen_WrongPredictionBis() public {
        // 1. add mockPriceFeed to simulate price feed
        _ownerAddMockPriceFeed(address(pPool));

        // 1.1. set mockPriceFeed return value
        mockPriceFeed.updateAnswer(100);

        /**
         * 2. player01 create a round on mockPriceFeed
         * - predict target price < mockPriceFeed (=> 100)
         * - predict downside
         */
        address feed = address(mockPriceFeed);
        uint256 target = 10;
        PredictionPool.BetSide betSide = PredictionPool.BetSide.Lt;
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);
        pPool.createRound{value: betValue}(feed, target, betSide, duration);

        PredictionPool.Round memory round = pPool.getRound(0);

        // 3. Resolve the round (simulate Chainlink Automation calling performUpkeep - here bypassing checkUpkeep)
        vm.warp(round.end + 1);
        uint256[] memory roundIds = new uint256[](1);
        roundIds[0] = round.id;

        vm.expectEmit();
        emit PredictionPool.PredictionPool_RoundResolved(round.id, player01, false);
        pPool.performUpkeep(abi.encode(roundIds));

        // 3.1. Verify the Round is Resolved
        PredictionPool.Round memory resolvedRound = pPool.getRound(round.id);
        assertEq(uint8(resolvedRound.status), uint8(PredictionPool.RoundStatus.Resolved));

        // 4. Claim reward as a NOT-winner
        vm.prank(player01);
        vm.expectRevert(PredictionPool_NotAWinner.selector);
        pPool.claimReward(round.id);

        // 4.1. Verify the reward was NOT claimed
        (,, bool claimed) = pPool.roundToPlayerBet(round.id, player01);
        assertEq(claimed, false);
    }

    function test_claimReward_RevertWhen_RoundNotResolved() public {
        // 1. add mockPriceFeed to simulate price feed
        _ownerAddMockPriceFeed(address(pPool));

        // 1.1. set mockPriceFeed return value
        mockPriceFeed.updateAnswer(100);

        /**
         * 2. player01 create a round on mockPriceFeed
         * - predict target price < mockPriceFeed (=> 100)
         * - predict upside
         */
        address feed = address(mockPriceFeed);
        uint256 target = 10;
        PredictionPool.BetSide betSide = PredictionPool.BetSide.Gte;
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);
        pPool.createRound{value: betValue}(feed, target, betSide, duration);

        PredictionPool.Round memory round = pPool.getRound(0);

        // 3. Verify the Round is NOT Resolved
        vm.warp(round.end - 10);
        PredictionPool.Round memory resolvedRound = pPool.getRound(round.id);
        assertEq(uint8(resolvedRound.status), uint8(PredictionPool.RoundStatus.Active));

        // 4. Claim reward as a winner
        vm.prank(player01);
        vm.expectRevert(PredictionPool_RoundNotResolved.selector);
        pPool.claimReward(round.id);

        // 4.1. Verify the reward was NOT claimed
        (,, bool claimed) = pPool.roundToPlayerBet(round.id, player01);
        assertEq(claimed, false);
    }

    function test_claimReward_RevertWhen_WinnerAlreadyClaimed() public {
        // 1. add mockPriceFeed to simulate price feed
        _ownerAddMockPriceFeed(address(pPool));

        // 1.1. set mockPriceFeed return value
        mockPriceFeed.updateAnswer(100);

        /**
         * 2. player01 create a round on mockPriceFeed
         * - predict target price < mockPriceFeed (=> 100)
         * - predict upside
         */
        address feed = address(mockPriceFeed);
        uint256 target = 10;
        PredictionPool.BetSide betSide = PredictionPool.BetSide.Gte;
        uint256 duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);
        pPool.createRound{value: betValue}(feed, target, betSide, duration);

        PredictionPool.Round memory round = pPool.getRound(0);

        // 3. Resolve the round (simulate Chainlink Automation calling performUpkeep - here bypassing checkUpkeep)
        vm.warp(round.end + 1);
        uint256[] memory roundIds = new uint256[](1);
        roundIds[0] = round.id;
        pPool.performUpkeep(abi.encode(roundIds));

        // 3.1. Verify the Round is Resolved
        PredictionPool.Round memory resolvedRound = pPool.getRound(round.id);
        assertEq(uint8(resolvedRound.status), uint8(PredictionPool.RoundStatus.Resolved));

        // 4. Claim reward as a winner
        vm.prank(player01);
        vm.expectEmit();
        emit PredictionPool.PredictionPool_RewardClaimed(round.id, player01, betValue);
        pPool.claimReward(round.id);

        // 4.1. Verify the reward was claimed
        (,, bool claimed) = pPool.roundToPlayerBet(round.id, player01);
        assertEq(claimed, true);

        // 5. Try to Claim reward again
        vm.prank(player01);
        vm.expectRevert(PredictionPool_AlreadyClaimed.selector);
        pPool.claimReward(round.id);

        // 4.1. Verify the reward is still marked as claimed
        (,, claimed) = pPool.roundToPlayerBet(round.id, player01);
        assertEq(claimed, true);
    }

    // === getBetWeight Tests ===
    /// @dev Tests that getBetWeight returns the correct weight for a bet.
    function test_getBetWeight() public {
        // 1. Create a round
        (PredictionPool.Round memory round,,,) = _player01CreateRound();

        // 2. Get the bet for player01
        (
            uint256 betAmount, // eth amount placed for this bet
            uint256 betTime, // timestamp when user placed its bet on roundId
            // bool claimed
        ) = pPool.roundToPlayerBet(round.id, player01);

        // 3. Get the bet weight for player01
        uint256 weight = pPool.getBetWeight(round.id, player01);

        // 4. Verify the weight is non-zero
        assertGt(weight, 0);

        // 5. Verify the weight is calculated correctly
        uint256 expectedTimeFactor = ((round.end - betTime) * 1e18) / pPool.minRoundDuration();
        uint256 expectedWeight = (betAmount * expectedTimeFactor) / 1e18;
        assertEq(weight, expectedWeight);
    }

    // === getTotalWeight Tests ===
    /// @dev Tests that getTotalWeight returns the correct total weight for a round.
    function test_getTotalWeight() public {
        // 1. Create a round
        (PredictionPool.Round memory round,,,) = _player01CreateRound();

        // 2. Add a second player's bet
        hoax(player02);
        pPool.betOn{value: betOnValue}(round.id, PredictionPool.BetSide.Lt);

        // 3. Get the total weight
        uint256 totalWeight = pPool.getTotalWeight(round.id);

        // 4. Verify the total weight is the sum of individual weights
        uint256 p1Weight = pPool.getBetWeight(round.id, player01);
        uint256 p2Weight = pPool.getBetWeight(round.id, player02);
        assertEq(totalWeight, p1Weight + p2Weight);
    }

    /// @dev Tests getTotalWeight with only GTE bets.
    function test_getTotalWeight_OnlyGteBets() public {
        (PredictionPool.Round memory round,,,) = _player01CreateRound();
        uint256 totalWeight = pPool.getTotalWeight(round.id);
        assertEq(totalWeight, pPool.getBetWeight(round.id, player01));
    }

    /// @dev Tests getTotalWeight with only LT bets.
    function test_getTotalWeight_OnlyLtBets() public {
        (PredictionPool.Round memory round,,,) = _player01CreateRound();
        hoax(player02);
        pPool.betOn{value: betOnValue}(round.id, PredictionPool.BetSide.Lt);
        uint256 totalWeight = pPool.getTotalWeight(round.id);
        assertEq(totalWeight, pPool.getBetWeight(round.id, player01) + pPool.getBetWeight(round.id, player02));
    }

    // === toggleAllowPriceFeed Tests ===
    /// @dev Tests that toggleAllowPriceFeed adds a new feed if not in list.
    function test_toggleAllowPriceFeed_AddNewFeed() public {
        address newFeed = makeAddr("newFeed");

        // Check before
        bool allowed = pPool.allowedDataFeeds(newFeed);
        assertEq(allowed, false);

        // *Add*
        vm.prank(owner);
        pPool.toggleAllowPriceFeed(newFeed);

        // Check after
        allowed = pPool.allowedDataFeeds(newFeed);
        assertEq(allowed, true);
    }

    function test_toggleAllowPriceFeed_Add_Emits_PriceFeedToggled_Event() public {
        // *Add*
        address newFeed = makeAddr("newFeed");
        bool enabled = true;
        vm.prank(owner);

        vm.expectEmit();
        emit PredictionPool.PredictionPool_PriceFeedToggled(newFeed, enabled);

        pPool.toggleAllowPriceFeed(newFeed);
    }

    /// @dev Tests that toggleAllowPriceFeed removes a feed if was in list.
    function test_toggleAllowPriceFeed_RemoveExistingFeed() public {
        // Check before
        bool allowed = pPool.allowedDataFeeds(SEPOLIA_LINK_USD);
        assertEq(allowed, true);

        // *Remove*
        vm.prank(owner);
        pPool.toggleAllowPriceFeed(SEPOLIA_LINK_USD);

        // Check after
        allowed = pPool.allowedDataFeeds(SEPOLIA_LINK_USD);
        assertEq(allowed, false);
    }

    function test_toggleAllowPriceFeed_Remove_Emits_PriceFeedToggled_Event() public {
        // *Remove*
        bool enabled = false;
        vm.prank(owner);

        vm.expectEmit();
        emit PredictionPool.PredictionPool_PriceFeedToggled(SEPOLIA_LINK_USD, enabled);

        pPool.toggleAllowPriceFeed(SEPOLIA_LINK_USD);
    }

    function test_toggleAllowPriceFeed_RevertWhen_Notowner() public {
        // Not-owner tries to toggle Allow PriceFeed
        vm.prank(player01);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        pPool.toggleAllowPriceFeed(SEPOLIA_LINK_USD);
    }

    function test_toggleAllowPriceFeed_RevertWhen_AddZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PredictionPool_ZeroAddressNotAllowed.selector);
        pPool.toggleAllowPriceFeed(zeroAddress);
    }

    // === setRoundDuration Tests ===
    /// @dev Tests that setRoundDuration sets a new round duration when called by owner.
    function test_setRoundDuration() public {
        // Check before
        uint256 minRoundDuration = pPool.minRoundDuration();
        assertEq(minRoundDuration, MIN_ROUND_DURATION);

        // owner change minRoundDuration
        vm.prank(owner);
        uint256 newDuration = 10 minutes;
        pPool.setRoundDuration(newDuration);

        // Check after
        minRoundDuration = pPool.minRoundDuration();
        assertEq(minRoundDuration, newDuration);
    }

    function test_setRoundDuration_Emits_NewMinRoundDuration_Event() public {
        // owner change minRoundDuration
        uint256 newDuration = 10 minutes;
        vm.prank(owner);

        vm.expectEmit();
        emit PredictionPool.PredictionPool_NewMinRoundDuration(newDuration);

        pPool.setRoundDuration(newDuration);
    }

    function test_setRoundDuration_RevertWhen_Notowner() public {
        // Not-owner tries to change minRoundDuration
        uint256 newDuration = 10 minutes;
        vm.prank(player01);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        pPool.setRoundDuration(newDuration);
    }

    function test_setRoundDuration_RevertWhen_InvalidDuration() public {
        // owner tries to change set minRoundDuration below STRICT_MIN_ROUND_DURATION
        uint256 newDuration = 1 minutes;
        vm.prank(owner);
        vm.expectRevert(PredictionPool_InvalidDuration.selector);
        pPool.setRoundDuration(newDuration);
    }

    // === getChainlinkDataFeedNormalizedPrice Tests ===
    /// @dev Tests that getChainlinkDataFeedNormalizedPrice returns the correct normalizedPrice from a valid priceFeed.
    function test_getChainlinkDataFeedNormalizedPrice() public {
        // 1. deploy MockOffchainAggregator
        // constructor(uint8 _decimals, int256 _initialAnswer)
        uint8 decimals = 8;
        int256 initialAnswer = 100;
        MockOffchainAggregator priceFeed = new MockOffchainAggregator(decimals, initialAnswer);

        // 2. owner adds priceFeed to allowedList
        vm.prank(owner);
        pPool.toggleAllowPriceFeed(address(priceFeed));

        // 3.
        uint256 expectedNormalizedPrice = uint256(initialAnswer) * (10 ** (18 - decimals));

        assertEq(pPool.getChainlinkDataFeedNormalizedPrice(address(priceFeed)), expectedNormalizedPrice);
    }

    function test_getChainlinkDataFeedNormalizedPrice_RevertWhen_InvalidDataFeedAddress() public {
        address invalidDataFeedAddress = makeAddr("invalidDataFeed");

        vm.expectRevert(PredictionPool_InvalidFeed.selector);
        pPool.getChainlinkDataFeedNormalizedPrice(invalidDataFeedAddress);
    }

    function test_getChainlinkDataFeedNormalizedPrice_RevertWhen_InvalidDataFeedDecimals() public {
        // 1. deploy MockOffchainAggregator with invalid decimals
        // constructor(uint8 _decimals, int256 _initialAnswer)
        uint8 invalidDecimals = 19;
        int256 initialAnswer = 100;
        MockOffchainAggregator invalidMockPriceFeed = new MockOffchainAggregator(invalidDecimals, initialAnswer);

        // 2. owner adds invalidMockPriceFeed to allowedList
        vm.prank(owner);
        pPool.toggleAllowPriceFeed(address(invalidMockPriceFeed));

        // 3. call getChainlinkDataFeedNormalizedPrice
        vm.expectRevert(abi.encodeWithSelector(PredictionPool_InvalidChainlinkDecimals.selector, invalidDecimals));
        pPool.getChainlinkDataFeedNormalizedPrice(address(invalidMockPriceFeed));
    }

    function test_getChainlinkDataFeedNormalizedPrice_RevertWhen_InvalidZeroDataFeedAnswer() public {
        // 1. deploy MockOffchainAggregator with invalid decimals
        // constructor(uint8 _decimals, int256 _initialAnswer)
        uint8 decimals = 18;
        int256 invalidInitialAnswer = 0;
        MockOffchainAggregator invalidMockPriceFeed = new MockOffchainAggregator(decimals, invalidInitialAnswer);

        // 2. owner adds invalidMockPriceFeed to allowedList
        vm.prank(owner);
        pPool.toggleAllowPriceFeed(address(invalidMockPriceFeed));

        // 3. call getChainlinkDataFeedNormalizedPrice
        vm.expectRevert(PredictionPool_NegativeChainlinkPrice.selector);
        pPool.getChainlinkDataFeedNormalizedPrice(address(invalidMockPriceFeed));
    }

    function test_getChainlinkDataFeedNormalizedPrice_RevertWhen_InvalidNegativeDataFeedAnswer() public {
        // 1. deploy MockOffchainAggregator with invalid decimals
        // constructor(uint8 _decimals, int256 _initialAnswer)
        uint8 decimals = 18;
        int256 invalidInitialAnswer = -1;
        MockOffchainAggregator invalidMockPriceFeed = new MockOffchainAggregator(decimals, invalidInitialAnswer);

        // 2. owner adds invalidMockPriceFeed to allowedList
        vm.prank(owner);
        pPool.toggleAllowPriceFeed(address(invalidMockPriceFeed));

        // 3. call getChainlinkDataFeedNormalizedPrice
        vm.expectRevert(PredictionPool_NegativeChainlinkPrice.selector);
        pPool.getChainlinkDataFeedNormalizedPrice(address(invalidMockPriceFeed));
    }

    // === Helpers ===
    function _player01CreateRound()
        internal
        returns (PredictionPool.Round memory round, address feed, uint256 target, uint256 duration)
    {
        feed = SEPOLIA_LINK_USD;
        target = uint256(1_000_000);
        duration = 2 minutes;

        // hoax => prank & fund
        hoax(player01);

        pPool.createRound{value: betValue}(feed, target, PredictionPool.BetSide.Gte, duration);

        round = pPool.getRound(0);
    }

    /**
     * simulate Chainlink Price Feeds
     */
    function _ownerAddMockPriceFeed(address _pPoolAddress) internal {
        // add mockPriceFeed to pPool allowed PriceFeeds list
        vm.prank(owner);
        PredictionPool(_pPoolAddress).toggleAllowPriceFeed(address(mockPriceFeed));
    }
}

