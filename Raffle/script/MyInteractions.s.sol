// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import {Script, console} from "forge-std/Script.sol";
import {HelperConfig, CodeConstants} from "./HelperConfig.s.sol";
import {VRFCoordinatorV2_5Mock} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {LinkToken} from "test/mocks/LinkToken.sol";
import {DevOpsTools} from "lib/foundry-devops/src/DevOpsTools.sol";

contract CreateSubscription is Script {
    function run() public {
        createSubscriptionUsingConfig();
    }

    function createSubscriptionUsingConfig() public returns (uint256, address) {
        HelperConfig helperConfig = new HelperConfig();

        address vrfCoordinator = helperConfig.getConfig().vrfCoordinator;
        console.log("Creating new subscription...");

        (uint256 subId, ) = createSubscription(vrfCoordinator);
        return (subId, vrfCoordinator);
    }

    function createSubscription(
        address vrfCoordinator
    ) public returns (uint256, address) {
        console.log(
            " subId need to be uploaded and vrfCoordinator is :",
            vrfCoordinator
        );
        vm.startBroadcast();
        uint256 subId = VRFCoordinatorV2_5Mock(vrfCoordinator)
            .createSubscription();
        vm.stopBroadcast();
        return (subId, vrfCoordinator);
    }
}

contract FundSubscription is Script, CodeConstants {
    uint256 public constant FUND_AMOUNT = 3 ether; //3 LINK

    function run() public {
        fundSubscriptionUsingConfig();
    }

    function fundSubscriptionUsingConfig() public {
        HelperConfig helperConfig = new HelperConfig();
        address vrfCoordinator = helperConfig.getConfig().vrfCoordinator;
        uint256 subId = helperConfig.getConfig().subscriptionId;
        //Adresse à laquelle tous les fonds sont verouillés
        address linkToken = helperConfig.getConfig().link;
        fundSubscription(vrfCoordinator, subId, linkToken);
    }

    //To fund a subscription we need vrfCoordinator address and subscription id
    function fundSubscription(
        address vrfCoordinator,
        uint256 subId,
        address linkToken
    ) public {
        console.log("Subscription id is :", subId);
        console.log("vrfCoordinator is:", vrfCoordinator);
        if (block.chainid == LOCAL_CHAIN_ID) {
            console.log("Anvil subscription funding...");
            vm.startBroadcast();
            VRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(
                subId,
                FUND_AMOUNT * 100
            );

            vm.stopBroadcast();
        } else {
            console.log("Sepolia subscription funding...");
            vm.startBroadcast();
            //C'est le jeton linkToken dont on souhaite transferer une certaine valeur
            //au contract vrfCoordinator
            LinkToken(linkToken).transferAndCall(
                vrfCoordinator,
                FUND_AMOUNT,
                abi.encode(subId)
            );
            vm.stopBroadcast();
        }
    }
}

contract AddConsumer is Script {
    function run() public {
        address mostRecentlyDeployed = DevOpsTools.get_most_recent_deployment(
            "Raffle",
            block.chainid
        );
        addConsumerUsingConfig(mostRecentlyDeployed);
    }

    function addConsumerUsingConfig(address mostRecentlyDeployed) public {
        HelperConfig helperConfig = new HelperConfig();
        address vrfCoordinator = helperConfig.getConfig().vrfCoordinator;
        uint256 subId = helperConfig.getConfig().subscriptionId;
        addConsumer(mostRecentlyDeployed, subId, vrfCoordinator);
    }

    function addConsumer(
        address contractToAddToVrf,
        uint256 subId,
        address vrfCoordinator
    ) public {
        console.log("Contract to add to vrf is :", contractToAddToVrf);
        console.log("Subscription id is :", subId);
        console.log("vrfCoordinator is:", vrfCoordinator);
        vm.startBroadcast();
        VRFCoordinatorV2_5Mock(vrfCoordinator).addConsumer(
            subId,
            contractToAddToVrf
        );
        vm.stopBroadcast();
    }
}
