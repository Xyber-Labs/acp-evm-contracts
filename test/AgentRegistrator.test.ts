import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { AgentManager, AgentRegistrator, ChainInfo, KeyStorage, Rotator } from "../typechain-types"
import hre, { ethers } from "hardhat";
import { main as deployMC } from "../scripts/deploy/assembled/deployMC"
import { loadDeploymentAddress } from "../utils/fileUtils";
import { expect } from "chai";

describe("AgentRegistrator", function() {
    let registrator: AgentRegistrator;
    let keyStorage: KeyStorage;
    let agentManager: AgentManager;
    let rotator: Rotator;
    let chainInfo: ChainInfo
    let owner: HardhatEthersSigner;
    let agent: HardhatEthersSigner;
    let superAgent: HardhatEthersSigner;

    this.timeout(600000)

    before(async() => {
        [owner, agent, superAgent] = await hre.ethers.getSigners()
        
        await deployMC()

        const registratorAddr = loadDeploymentAddress("hardhat", "AgentRegistrator")
        registrator = await ethers.getContractAt("AgentRegistrator", registratorAddr, owner)

        const keyStorageAddr = loadDeploymentAddress("hardhat", "KeyStorage")
        keyStorage = await ethers.getContractAt("KeyStorage", keyStorageAddr, owner)

        const rotatorAddr = loadDeploymentAddress("hardhat", "Rotator")
        rotator = await ethers.getContractAt("Rotator", rotatorAddr, owner)

        const chainInfoAddr = loadDeploymentAddress("hardhat", "ChainInfo")
        chainInfo = await ethers.getContractAt("ChainInfo", chainInfoAddr, owner)

        const mngrAddr = loadDeploymentAddress("hardhat", "AgentManager")
        agentManager = await ethers.getContractAt("AgentManager", mngrAddr, owner)
        await agentManager.setRotator(await rotator.getAddress())
        await agentManager.setChainInfo(chainInfoAddr)

        await registrator.setKeyStorage(keyStorageAddr)
        await registrator.setAgentManager(mngrAddr)
        await registrator.setDefKeyLen(4)
    })

    it("should register agent", async function () {
        const chainId = 1
        const agentAddr = agent.address
        let keys: Uint8Array[] = [];
        for (let i = 0; i < 4; i++) {
            keys[i] = ethers.randomBytes(10)
        }

        const tx = await registrator.registerAgent(chainId, agentAddr, keys)

        await expect(tx)
            .to.emit(keyStorage, "KeySet")
            .to.emit(agentManager, "AgentAdded")
    })

    it("should register super agent", async function () {
        const agentAddr = superAgent.address
        let keys: Uint8Array[] = [];
        for (let i = 0; i < 4; i++) {
            keys[i] = ethers.randomBytes(10)
        }

        const tx = await registrator.registerSuperAgent(agentAddr, keys)

        await expect(tx)
            .to.emit(keyStorage, "KeySet")
            .to.emit(chainInfo, "SuperConsensusRateChanged")
            .to.emit(agentManager, "AgentAdded")
    })
})