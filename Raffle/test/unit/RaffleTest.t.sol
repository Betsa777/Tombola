// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/Script.sol";
import {DeployRaffle} from "script/DeployRaffle.s.sol";
import {Raffle} from "src/Raffle.sol";
import {HelperConfig, CodeConstants} from "script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2_5Mock} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract RaffleTest is Test, CodeConstants {
    Raffle public raffle;
    HelperConfig public helperConfig;

    uint256 entraceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint32 callbackGasLimit;
    uint256 subscriptionId;
    /*Un playeur vient d'entrer dans la tombola*/
    event RaffleEntered(address indexed player);
    /*Un gagnat a été choisi*/
    event WinnerPick(address indexed winner);
    address public PLAYER = makeAddr("player");

    uint256 public constant STARTING_PLAYER_BALANCE = 10 ether;

    function setUp() public {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.deployContract();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        entraceFee = config.entraceFee;
        interval = config.interval;
        vrfCoordinator = config.vrfCoordinator;
        gasLane = config.gasLane;
        callbackGasLimit = config.callbackGasLimit;
        subscriptionId = config.subscriptionId;
        /*Give a balance of 10 ether to player*/
        vm.deal(PLAYER, STARTING_PLAYER_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    /*Testing raffle*/
    function testRaffleRevertsWhenYouDontPayEnough() public {
        //Arrange
        vm.prank(PLAYER);
        //Act asset

        vm.expectRevert(Raffle.Raffle__sendMoreToEnterRaffle.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsPlayersWhenTheyEnter() public {
        //Arrange
        vm.prank(PLAYER);
        //Act
        raffle.enterRaffle{value: entraceFee}();
        //Asset
        address playerRecorded = raffle.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEnteringRaffleEmitsEvent() public {
        //Arrange
        vm.prank(PLAYER);
        //Act
        //event RaffleEntered(address indexed player);
        //true parce que address indexed player , si c'eatit address player ce serait false
        vm.expectEmit(true, false, false, false, address(raffle));
        emit RaffleEntered(PLAYER);
        //assert
        raffle.enterRaffle{value: entraceFee}();
    }

    modifier raffleEntered() {
        //Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: 0.01 ether}();
        //change block.timestamp
        vm.warp(block.timestamp + interval + 1);
        //change block.number
        vm.roll(block.number + 1);
        _;
    }

    function testDontAllowPlayersToEnterWhileRaffleIsCalculating()
        public
        raffleEntered
    {
        raffle.performUpkeep("");
        //act /Assert
        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entraceFee}();
    }

    /*******CHECK UPKEEP********/
    function testUpkeepReturnsFalseIfItHasNoBalance() public {
        //Arrange
        vm.warp(block.timestamp + interval + 1);
        //change block.number
        vm.roll(block.number + 1);

        //Act
        // (bool upkeepNeeded, ) = raffle.checkUpKeep("");
        //assert(!upkeepNeeded);
    }

    function testUpkeepReturnsFalseIfRaffleIsntOpen() public {
        //Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entraceFee}();
        vm.warp(block.timestamp + interval + 1);
        //change block.number
        vm.roll(block.number + 1);
        raffle.performUpkeep("");
        //Act
        // (bool upkeepNeeded, ) = raffle.checkUpKeep("");
        // //Assert
        // assert(!upkeepNeeded);
    }

    function testUpkeepReturnsFalseIfEnoughTimeHasntPassed() public {
        //Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entraceFee}();
        //Act
        // (bool upkeepNeeded, ) = raffle.checkUpKeep("");
        // //Assert
        // assert(!upkeepNeeded);
    }

    function testUpkeepReturnsTrueWHenParametersAreGood() public {
        //Arrange
        vm.prank(PLAYER);
        vm.warp(block.timestamp + interval + 1);
        //change block.number
        vm.roll(block.number + 1);
        raffle.enterRaffle{value: entraceFee}();

        //Act
        // (bool upkeepNeeded, ) = raffle.checkUpKeep("");
        // //Assert
        // assert(upkeepNeeded);
    }

    /********PERFORM UPKEEP********/
    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue() public {
        //Arrange
        vm.prank(PLAYER);
        vm.warp(block.timestamp + interval + 1);
        //change block.number
        vm.roll(block.number + 1);
        raffle.enterRaffle{value: entraceFee}();
        //Act/Assert
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        //Arrange
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        Raffle.RaffleState rState = raffle.getRaffleState();
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entraceFee}();
        numPlayers = 1;
        currentBalance = currentBalance + entraceFee;
        //Act / Assert
        vm.expectRevert(
            abi.encodeWithSelector(
                Raffle.Raffle__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                rState
            )
        );
        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitsRequestId() public {
        //Arrange
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entraceFee}();
        vm.warp(block.timestamp + interval + 1);
        //change block.number
        vm.roll(block.number + 1);

        //Act
        /*Tous les logs et events emis stockés les dans entries
          C'est pour nous razssurer qu'une fonction fonctionne normalement
          et on peut ajouter une evènement(event) à la fin de la fonction.
          Si le event est declenché c'est que la fonction fonctionne normalement.*/
        /* 
          Topics are any event parameters

          */
        //vm.recordLogs(); garde les traces des logs et events emis par la fonction
        //qui suit c'est à raffle.performUpkeep("")
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[0];

        //Assert
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        assert(uint256(requestId) > 0);
        assert(uint256(raffleState) == 1);
    }

    /* FULFILLRANDOMWORDS*/

    function testFulFillRandomWordsCanOnlyBeCallAfterPerformUpkeep(
        uint256 randomRequestId /*Génère jusqu'à 256 valeurs de tests */
    ) public raffleEntered {
        //Arrange /Act / Assert
        vm.expectRevert(VRFCoordinatorV2_5Mock.InvalidRequest.selector);
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(
            randomRequestId,
            address(raffle)
        );
    }

    /*On ajoute ca parce que en effectuant le test sur le 
    fork url le 
     VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        ); pretend etre les noeuds chainlink pourtant sur sepolia par exemple
         le noeuds chainlink doivent recevoir la requete et renvoyé les nombres.
         C'est pourquoi en effectuant les tests sans le modifier skipFork
         les tests testFulFillRandomWordsPicksAWinnerResetsAndSendsMoney et
          testFulFillRandomWordsCanOnlyBeCallAfterPerformUpkeep echouent 
          parceque en utilisant le mock il génère des nombres aléatoires à la place
          des noeuds chainlink réels.*/
    modifier skipFork() {
        if (block.chainid != LOCAL_CHAIN_ID) {
            return;
        }
        _;
    }

    function testFulFillRandomWordsPicksAWinnerResetsAndSendsMoney()
        public
        raffleEntered
        skipFork
    {
        //Arrange
        uint256 additionalEntrants = 3; //4 people total in the raffle
        uint256 startingIndex = 1;
        address expectedWinner = address(1);
        for (
            uint256 i = startingIndex;
            i < startingIndex + additionalEntrants;
            i++
        ) {
            address newPlayer = address(uint160(i)); //address(1)..address(3)
            //uint160 parce qu'une adresse sur ethereum est sur 160 bits
            hoax(newPlayer, 1 ether);
            raffle.enterRaffle{value: entraceFee}();
        }
        uint256 startingTime = raffle.getLastTimestamp();
        uint256 winnerstartingBalance = expectedWinner.balance;
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        /* 
        topics: An array of indexed event parameters.
        data: The non-indexed data of the event.
        */
        bytes32 requestId = entries[1].topics[1];
        VRFCoordinatorV2_5Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        );
        //Act
        address recentWinner = raffle.getRecentWinner();
        Raffle.RaffleState raffleState = raffle.getRaffleState();
        uint256 winnerBalance = recentWinner.balance;
        uint256 endingTimeStamp = raffle.getLastTimestamp();
        uint256 prize = entraceFee * (additionalEntrants + 1);

        assert(recentWinner == expectedWinner);
        assert(uint256(raffleState) == 0);
        assert(winnerBalance == winnerstartingBalance + prize);
        assert(endingTimeStamp > startingTime);
    }

    function testEntranceFee() public view {
        assert(raffle.getEntranceFee() == 1e16);
    }
}
