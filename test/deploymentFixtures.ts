import hre, { ethers, upgrades } from "hardhat";
import {
    AgentManager,
    Endpoint,
    Master,
    MessageData,
    ExecutorLottery,
    KeyStorage,
    RewardVaults,
    Rotator,
    PingSystem
} from "../typechain-types";

// depoy solo
import { main as deployEndpoint } from "../scripts/deploy/Endpoint"
import { main as deployConfigurator } from "../scripts/deploy/Configurator"
import { main as deployMaster } from "../scripts/deploy/Master"
import { main as deployAgentManager } from "../scripts/deploy/AgentManager"
import { main as deployMessageData } from "../scripts/deploy/MessageData"
import { main as deployKeyStorage } from "../scripts/deploy/KeyStorage"
import { main as deployRewardVaults } from "../scripts/deploy/RewardVaults"
import { main as deployRotator } from "../scripts/deploy/Rotator"
import { main as deployPingSystem } from "../scripts/deploy/PingSystem";

// deploy suites
import { main as deployAllCore } from "../scripts/deploy/assembled/deployMC"
import { deployEndpointOneNet as deployEndpointSuite } from "../scripts/deploy/assembled/DeployEVM"

async function deployAll() {
    await deployAllCore();
    await deployEndpointSuite();
}

async function deployMC() {
    await deployAllCore()
}

async function deployAllEndpoint() {
    await deployEndpointSuite()
}

async function deployKeyStorageFixture() {
    const keystorage = await deployKeyStorage()
    
    return keystorage as unknown as KeyStorage;
}

async function deployRotatorFixture() {
    const rotator = await deployRotator()

    return rotator as unknown as Rotator;
}

async function deployRewardVaultsFixture() {
    const rw = await deployRewardVaults()

    return rw as unknown as RewardVaults;
}

async function deployEndPointFixture() {
    const owner = await getAdmin();
    const signers = await ethers.getSigners();

    const endpoint = await deployEndpoint();
    const configurator = await deployConfigurator();
    await endpoint.setConfigurator(configurator.target);

    const signerAddresses = signers.slice(1, 7).map((s) => s.address);

    await endpoint.activateOrDisableSignerBatch(
        signerAddresses,
        [true, true, true, true, true, true]
    );
    // console.log("==========")
    // console.log(signers.slice(1, 7).length)

    await endpoint.activateOrDisableExecutorBatch(
        signerAddresses,
        [true, true, true, true, true, true]
    )
    await endpoint.setConsensusTargetRate(5000); // 50%

    return endpoint as unknown as Endpoint;
}

async function deployMasterFixture() {
    const owner = await getAdmin();
    const master = await deployMaster()

    return master as unknown as Master;
}

async function deployAMFixture() {
    const owner = await getAdmin();
    const agentManager = deployAgentManager()

    return agentManager as unknown as AgentManager;
}

async function deployMessageDataFixture() {
    const owner = await getAdmin();
    const msgData = await deployMessageData()

    return msgData as unknown as MessageData;
}

async function deployPingSystemFixture() {
    const pingSystem = await deployPingSystem();

    return pingSystem as unknown as PingSystem;
}

// requires Master
async function deployLotteryFixture() {
    const owner = await getAdmin();
    const factory = await loadFactory("ExecutorLottery");
    const args: any = [
        [
            await owner.getAddress(), 
            await owner.getAddress(), 
        ]
    ];
    const lottery = await simpleDeploy(factory, args);

    return lottery as unknown as ExecutorLottery;
} 

// async function deployMessengerFixture(endpoint:string) {
//     const owner = await getAdmin()
//     const factory = await loadFactory("MessengerProtocol");
//     const args: any = [
//         await owner.getAddress(),
//         endpoint
//     ]
//     const msgr = await simpleDeploy(factory, args)

//     return msgr as unknown as MessengerProtocol
// }   

async function getAdmin() {
    const [admin] = await ethers.getSigners();
    return admin;
}

async function loadFactory(name: string) {
    const factory = await hre.ethers.getContractFactory(name);
    return factory;
}

async function simpleDeploy(factory: any, args: any) {
    const contract = await upgrades.deployProxy(factory, args, {
        kind: "uups",
    });
    await contract.waitForDeployment();

    return contract;
}

export {
    deployKeyStorageFixture,
    deployEndPointFixture,
    deployMasterFixture,
    deployAMFixture,
    deployMessageDataFixture,
    deployPingSystemFixture,
    deployLotteryFixture,
    deployRewardVaultsFixture,
    deployMC,
    deployAll,
    deployAllEndpoint,
    deployRotatorFixture
};
