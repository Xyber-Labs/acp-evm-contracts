import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
    AgentManager,
    AgentRegistrator,
    PingSystem,
    Rewards,
    Staking,
    TokenMock
} from "../typechain-types"
import { loadDeploymentAddress } from "../utils/fileUtils";
import { main as deployMC } from "../scripts/deploy/assembled/deployMC"
import hre, { ethers, upgrades } from "hardhat";
import { expect } from "chai";

async function deploytoken() {
    const tokenFactory = await ethers.getContractFactory("TokenMock");
    const token = await tokenFactory.deploy();
    await token.waitForDeployment()

    return token as unknown as TokenMock;
}

describe("AgentManager", function() {
    let agentManager: AgentManager;
    let agentRegistrator: AgentRegistrator;
    let pingSystem: PingSystem;
    let rewards: Rewards;
    let staking: Staking

    let owner: HardhatEthersSigner;
    let agent1: HardhatEthersSigner;
    let agent2: HardhatEthersSigner;

    const CHAIN_ID = 1;

    const agentData = {
        chainID: CHAIN_ID,
        agentType: 1,
        status: 0,
    };
  
    this.timeout(600000);

    before(async function () {
        [owner, agent1, agent2] = await ethers.getSigners();

        await deployMC();

        const agentRegistratorAddress = loadDeploymentAddress("hardhat", "AgentRegistrator");
        agentRegistrator = await ethers.getContractAt("AgentRegistrator", agentRegistratorAddress, owner);

        const keyStorageAddress = loadDeploymentAddress("hardhat", "KeyStorage");
        await agentRegistrator.setKeyStorage(keyStorageAddress);

        const managerAddress = loadDeploymentAddress("hardhat", "AgentManager");
        agentManager = await ethers.getContractAt("AgentManager", managerAddress, owner);

        const stakingAddress = loadDeploymentAddress("hardhat", "Staking");
        staking = await ethers.getContractAt("Staking", stakingAddress, owner);

        await agentRegistrator.setAgentManager(managerAddress);

        await agentManager.grantRole(await agentManager.RECEPTION(), owner.address);
        await agentManager.grantRole(await agentManager.ROTATOR(), owner.address);

        const rotatorAddr = loadDeploymentAddress("hardhat", "Rotator");
        const chainInfoAddr = loadDeploymentAddress("hardhat", "ChainInfo");
        const rewardsAddr = loadDeploymentAddress("hardhat", "Rewards");
        const pingSystemAddr = loadDeploymentAddress("hardhat", "PingSystem");

        pingSystem = await ethers.getContractAt("PingSystem", pingSystemAddr, owner);
        rewards = await ethers.getContractAt("Rewards", rewardsAddr, owner);

        await pingSystem.setKeyStorage(keyStorageAddress);

        await agentManager.setRotator(rotatorAddr);
        await agentManager.setChainInfo(chainInfoAddr);
        await agentManager.setRewards(rewardsAddr);
        await agentManager.setPingSystem(pingSystemAddr);

        const token = await deploytoken();
        await staking.setWNative(token.target)
        // await rewardVauls.setToken(token.target);
    });

    it("should register agents", async function() {
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agent1.address);

        const registeredAgent1 = await agentManager.allAgents(agent1.address);
        expect(registeredAgent1.agentType).to.equal(1);
        expect(registeredAgent1.status).to.equal(2);
        expect(registeredAgent1.chainID).to.equal(CHAIN_ID);

        await expect(agentManager.registerAgentBatch(
            [agent2.address], 
            [{...agentData, agentType: 2}]
        )).to.emit(agentManager, "AgentAdded");     
        
        const registeredAgent2 = await agentManager.allAgents(agent2.address);
        expect(registeredAgent2.agentType).to.equal(2);
        expect(registeredAgent2.status).to.equal(2);
        expect(registeredAgent2.chainID).to.equal(CHAIN_ID);
    });
    

    it("should revert if trying to register an already registered agent", async function() {
        await expect(agentManager.registerAgent(agent1.address, agentData))
          .to.be.revertedWithCustomError(agentManager, "AgentManager__AlreadyCondidate");
    });

    it("should correctly handle agent status activation", async () => {
        await agentManager.activateAgents([agent1.address]);
    
        const updatedAgent = await agentManager.allAgents(agent1.address);
        expect(updatedAgent.status).to.equal(1);
    });

    it("should revert if agent status change is attempted for a non-registered agent", async function () {
        await expect(agentManager.activateAgents([ethers.ZeroAddress]))
          .to.be.revertedWithCustomError(agentManager, "AgentManager__AgentNotRegistered");
    });
    
    it("should allow to set participants", async function() {
        await agentManager.setParticipants(CHAIN_ID, 0, [agent1.address]);
    
        const participants = await agentManager.getCurrentParticipants(CHAIN_ID);
        expect(participants).to.include(agent1.address);
    });

    it("Should activate/deactivate agents", async function() {
        await agentManager.activateAgents([agent1.address]);
        expect(await agentManager.getStatus(agent1.address)).to.equal(1);
    
        await agentManager.deactivateAgents([agent1.address]);
        expect(await agentManager.getStatus(agent1.address)).to.equal(2);
    });

    it("Should allow to force drop agents", async () => {
        await agentManager.setForceDroppedAgent(CHAIN_ID, 1, agent1.address);
        const dropped = await agentManager.getForceDroppedAgents(CHAIN_ID, 1);
        expect(dropped).to.include(agent1.address);
    });

    it("Should filter candidates correctly", async () => {        
        await pingSystem.connect(agent1).ping();
        await staking.connect(agent1).deposit(agent1.address, 0, { value: ethers.parseEther("1") });
    
        const filtered = await agentManager.getFilteredCandidates(CHAIN_ID, 1);
        expect(filtered).to.include(agent1.address);
    });
});