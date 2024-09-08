// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import {Script} from "forge-std/Script.sol";
import {Raffle} from "src/Raffle.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {CreateSubcription, FundSubscription, AddConsumer} from "script/Interactions.s.sol";

contract DeployRaffle is Script {
    function run() public {
        deployContract();
    }

    function deployContract() public returns (Raffle, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        //local -> deploy mock,get local config
        //sepolia -> get sepolia config
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        //if chainId = 31337 anvil chain
        if (config.subscriptionId == 0) {
            //create  subcription
            CreateSubcription createSubscription = new CreateSubcription();
            (config.subscriptionId, config.vrfCoordinator) = createSubscription
                .createSubscription(config.vrfCoordinator, config.account);
            //fund subscription
            FundSubscription fundSubscription = new FundSubscription();
            fundSubscription.fundSubscription(
                config.vrfCoordinator,
                config.subscriptionId,
                config.link,
                config.account
            );
        }
        vm.startBroadcast(config.account);
        Raffle raffle = new Raffle(
            config.entraceFee,
            config.interval,
            config.vrfCoordinator,
            config.gasLane,
            config.callbackGasLimit,
            config.subscriptionId
        );
        vm.stopBroadcast();
        AddConsumer addConsumer = new AddConsumer();
        //don't need to broadcast
        addConsumer.addConsumer(
            address(raffle),
            config.vrfCoordinator,
            config.subscriptionId,
            config.account
        );
        return (raffle, helperConfig);
    }
}
