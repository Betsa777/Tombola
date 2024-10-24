// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Raffle} from "src/Raffle.sol";
import {CreateSubscription, FundSubscription, AddConsumer} from "./MyInteractions.s.sol";
import {Random} from "../src/Random.sol";
import {VRFCoordinatorV2_5Mock} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract Deploy is Script {
    function run() public {
        deployContract();
    }

    function deployContract()
        public
        returns (Random, HelperConfig.NetworkConfig memory)
    {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        if (config.subscriptionId == 0) {
            //create subscription
            CreateSubscription createSubscription = new CreateSubscription();
            (config.subscriptionId, config.vrfCoordinator) = createSubscription
                .createSubscription(config.vrfCoordinator);
            //fund subscription
            FundSubscription fundSubscription = new FundSubscription();
            fundSubscription.fundSubscription(
                config.vrfCoordinator,
                config.subscriptionId,
                config.link
            );
        }
        vm.startBroadcast();
        Random rand = new Random(VRFCoordinatorV2_5Mock(config.vrfCoordinator));
        vm.stopBroadcast();
        //Add consumer -> utiliser VRF dans le contract Raffle
        AddConsumer addConsumer = new AddConsumer();
        // console.log("Contract is :", raffle);
        // console.log("Is address is: ", address(raffle));
        addConsumer.addConsumer(
            address(rand),
            config.subscriptionId,
            config.vrfCoordinator
        );
        console.log("Contract address is :", address(rand));
        return (rand, config);
    }
}
