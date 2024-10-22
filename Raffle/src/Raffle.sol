// Pragma statements

// Import statements

// Events

// Errors

// Interfaces

// Libraries

// Contracts

// Inside each contract, library or interface, use the following order:

// Type declarations

// State variables

// Events

// Errors

// Modifiers

// Functions
// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {VRFCoordinatorV2_5Mock} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

/**
 * @title A sample raffle contract
 * @author Betsaleel Dakuyo
 * @notice This contract is for created a simple raffle
 * @dev Implements chainlink VRFv2.5
 */
contract Raffle is VRFConsumerBaseV2Plus, AutomationCompatibleInterface {
    /*Errors*/
    error Raffle__sendMoreToEnterRaffle();
    error Raffle_TransferFailed();
    error Raffle__RaffleNotOpen();
    error Raffle__UpkeepNotNeeded(
        uint256 balance,
        uint256 playersLenth,
        uint256 raffleState
    );
    /*Type declarations*/

    enum RaffleState {
        OPEN,
        CALCULATING
    }
    /*State variables*/

    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;
    uint256 private immutable i_entranceFee;
    // @dev the duration of the lottery in seconds
    uint256 private immutable i_interval;
    uint256 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    bytes32 private immutable i_keyHash;
    uint256 private s_lastTimeStamp;
    address private s_recentWinner;
    RaffleState private s_raffleState; //start as open

    /*Events*/
    /*Un playeur vient d'entrer dans la tombola*/
    event RaffleEntered(address indexed player);
    /*Un gagnat a été choisi*/
    event WinnerPick(address indexed winner);
    event RequestedRaffleWinner(uint256 indexed requestId);

    address payable[] private s_players;

    constructor(
        uint256 entraceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint32 callbackGasLimit,
        uint256 subscriptionId
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_entranceFee = entraceFee;
        i_interval = interval;
        //The most block.timestamp
        i_keyHash = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;
        s_lastTimeStamp = block.timestamp;
        s_raffleState = RaffleState.OPEN;
    }

    /*Permet aux utilisateurs d'entrer dans la tombola*/
    function enterRaffle() external payable {
        /*En utilisant Not enough eth sent! ca coute du gas. Plutot utiliser des erreurs customisés*/
        // require(msg.value >= i_entranceFee, "Not enough eth sent!");
        //require(msg.value >=i_entranceFee , sendMoreToEnterRaffle());
        if (msg.value < i_entranceFee) {
            revert Raffle__sendMoreToEnterRaffle();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        s_players.push(payable(msg.sender));
        //1. Makes migration easier
        //2. Makes frontend indexing easier
        emit RaffleEntered(msg.sender);
    }

    //When should the winner be picked
    /**
     * @dev this is the function that chainlink nodes we call to see
     * if the lottery is ready to have a winner picked.
     * The following should be true in order for upkeepNeeded to be true
     * 1.The time interval has passed before raffle runs
     * 2.The lottery is open
     * 3.The contract has ETH (has players)
     * 4.Implicitly, your subscription has LINK
     * @param - ignored
     * @return upkeepNeeded - true if it's time to restrart lottery
     * @return - ignored
     */
    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        bool timeHasPassed = ((block.timestamp - s_lastTimeStamp) >=
            i_interval);
        bool isOpen = s_raffleState == RaffleState.OPEN;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;
        upkeepNeeded = (timeHasPassed && isOpen && hasBalance && hasPlayers);
        return (upkeepNeeded, "");
    }

    /*Choisit un vainqueur parmi la liste des participants*/
    //1. Get a randomnumber
    //2. Use random number to pick a player
    //3. Be automatically called
    //Include a performUpkeep function that will be executed onchain when checkUpkeep returns true.
    function performUpkeep(bytes calldata /* performData */) external override {
        //check to see if enough time has passed
        (bool upkeepNeeded, ) = checkUpkeep("");

        if (!upkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_raffleState)
            );
        }
        s_raffleState = RaffleState.CALCULATING;
        //keyHash : the gas lane or gas you want to pay
        //NUM_WORDS : the number of random number you want
        uint256 requestID = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    //set nativePayment to true to pay in Eth sepolia instead of LINK
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                ) // new parameter
            })
        );

        /*Emitted this request is redundant because chainlink VRF already emit this request*/
        emit RequestedRaffleWinner(requestID);
    }

    /*Cette fonction est appelée après chaque s_vrfCoordinator.requestRandomWords()*/
    //CEI: checks , Effects , Interactions pattern
    function fulfillRandomWords(
        uint256,
        /* requestId,*/ uint256[] calldata randomWords
    ) internal override {
        //checks -> require or conditionnal like if(value==10)

        //Effect (Internal contract state)
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable recentWinner = s_players[indexOfWinner];
        s_recentWinner = recentWinner;
        s_raffleState = RaffleState.OPEN;
        /*Après avoir choisi un vainqueur on remet la liste des joueurs à 0*/
        s_players = new address payable[](0);
        /*On remet le compteur a block.timestamp a nouveua pour que le temps de l'interval soit respecté*/
        s_lastTimeStamp = block.timestamp;
        emit WinnerPick(s_recentWinner);
        //Interactions (External contract interactions)
        (bool success, ) = recentWinner.call{value: address(this).balance}("");
        if (!success) {
            revert Raffle_TransferFailed();
        }
    }

    /*Getters functions */
    /*Fonction pour avoir les frais minimum qu'un participant doit payer pour participer à la tombola*/
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getRaffleState() public view returns (RaffleState) {
        return s_raffleState;
    }

    function getPlayer(uint256 indexOfPlayer) external view returns (address) {
        return s_players[indexOfPlayer];
    }

    function getLastTimestamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }
    // function vrfCor() public{
    //      uint256 requestID = s_vrfCoordinator.requestRandomWords(
    //         VRFV2PlusClient.RandomWordsRequest({
    //             keyHash: i_keyHash,
    //             subId: i_subscriptionId,
    //             requestConfirmations: REQUEST_CONFIRMATIONS,
    //             callbackGasLimit: i_callbackGasLimit,
    //             numWords: NUM_WORDS,
    //             extraArgs: VRFV2PlusClient._argsToBytes(
    //                 //set nativePayment to true to pay in Eth sepolia instead of LINK
    //                 VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
    //             ) // new parameter
    //         })
    //     );
    //    VRFCoordinatorV2_5Mock(s_vrfCoordinator).fulfillRandomWords(requestID,);
    // }
}
