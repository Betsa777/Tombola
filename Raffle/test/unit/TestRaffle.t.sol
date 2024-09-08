// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import {Test} from "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {Raffle} from "src/Raffle.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2_5Mock} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract TestRaffle is Test {
    address public PLAYER = makeAddr("PLAYER");
    HelperConfig public helperConfig;
    Raffle public raffle;
    uint256 public constant ETHER_AMOUNT = 10 ether;
    /*Un playeur vient d'entrer dans la tombola*/
    event RaffleEntered(address indexed player);
    /*Un gagnat a été choisi*/
    event WinnerPick(address indexed winner);

    uint256 entraceFee = entraceFee;
    uint256 interval = interval;
    address vrfCoordinator = vrfCoordinator;
    bytes32 gasLane;
    uint32 callbackGasLimit;
    uint256 subscriptionId;

    function setUp() public {
        Deploy deployer = new Deploy();
        (raffle, helperConfig) = deployer.deployContract();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        entraceFee = config.entraceFee;
        interval = config.interval;
        vrfCoordinator = config.vrfCoordinator;
        gasLane = config.gasLane;
        callbackGasLimit = config.callbackGasLimit;
        subscriptionId = config.subscriptionId;
        vm.deal(PLAYER, ETHER_AMOUNT);
    }

    function testRaffleState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRevertWirhInsuficient() public {
        vm.prank(PLAYER);
        vm.expectRevert(Raffle.Raffle__sendMoreToEnterRaffle.selector);
        raffle.enterRaffle();
    }

    function testTryAgainRaffleEntering() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: 0.01 ether}();
        address player = raffle.getPlayer(0);
        assert(player == PLAYER);
    }

    function testPlayerEnteringInRaffleEvent() public {
        vm.prank(PLAYER);

        vm.expectEmit(true, false, false, false, address(raffle));
        emit RaffleEntered(PLAYER);

        raffle.enterRaffle{value: 0.01 ether}();
    }

    modifier raffleEntered() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entraceFee}();

        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    function testPlayersDontEnterInRaffleWhenCalculating()
        public
        raffleEntered
    {
        //Arrange

        //while permorfing Upkeep raffle is calculating
        raffle.performUpkeep("");
        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        raffle.enterRaffle{value: entraceFee}();
    }

    function testFulFillRandomWordsPicksAWinnerResetsAndSendMoney()
        public
        raffleEntered
    {
        uint256 startingIndex = 1;
        uint256 additionalPlayers = 3;
        address expectedWinner = address(1);
        for (
            uint256 i = startingIndex;
            i < startingIndex + additionalPlayers;
            i++
        ) {
            address newPlayer = address(uint160(i));
            hoax(newPlayer, 1 ether);
            raffle.enterRaffle{value: entraceFee}();
        }
        uint256 startingTimeStamp = raffle.getLastTimestamp();
        uint256 winnerStartingBalance = expectedWinner.balance;
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1]; //topics -> indexed parameters
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        );

        address recentWinner = raffle.getRecentWinner();
        uint256 endingTimeStamp = raffle.getLastTimestamp();
        uint256 price = entraceFee * (additionalPlayers + 1);
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        assert(expectedWinner == recentWinner);
        assert(uint256(raffleState) == 0);
        assert(endingTimeStamp > startingTimeStamp);
        assert(recentWinner.balance == winnerStartingBalance + price);
    }
}
