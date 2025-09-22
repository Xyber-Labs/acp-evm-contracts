import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { deployMasterFixture, deployAMFixture, deployMessageDataFixture, deployMC } from "./deploymentFixtures";
import { log } from "./testLogger";
import { getChainDataHash, getPrefixedMsg, getTestMsg, signSolo, getTestRawMsg } from "./testUtils";
import { AgentLib } from "../typechain-types/contracts/agents/AgentManager";
import { AgentManager, KeyStorage, Master, MessageData, RotatorMock } from "../typechain-types";
import { TEST_DEST_CHAIN_ID } from "../utils/constants";
import { loadInstance } from "../utils/scriptUtils";
import { isConditionalTypeNode } from "typescript";
import { AgentRegistrator } from "../typechain-types";
import exp from "constants";

describe("Master", function () {
    this.timeout(600000)

    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;

    let agent1: HardhatEthersSigner;
    let agent2: HardhatEthersSigner;
    let agent3: HardhatEthersSigner;
    let agents: HardhatEthersSigner[] = [];

    // e2e or common state
    let master: Master;
    let amgr: AgentManager;
    let md: MessageData;
    let keyStorage: KeyStorage;
    let agrgr: AgentRegistrator;

    before(async () => {
        const coder = ethers.AbiCoder.defaultAbiCoder();

        await deployMC()
        
        signers = await ethers.getSigners();
        owner = signers[0];
        agent1 = signers[1];
        agent2 = signers[2];
        agent3 = signers[3];
        
        agrgr = await loadInstance("hardhat", "AgentRegistrator", true) 
        master = await loadInstance("hardhat", "Master", true)
        amgr = await loadInstance("hardhat", "AgentManager", true)
        md = await loadInstance("hardhat", "MessageData", true)
        keyStorage = await loadInstance("hardhat", "KeyStorage", true)

        const ownerAddr = await owner.getAddress();

        let keys: Uint8Array[] = [];
        for (let i = 0; i < 4; i++) {
            keys[i] = ethers.randomBytes(10)
        }

        await agrgr.registerSuperAgent(ownerAddr, keys)

        await amgr.forceRegisterSuperAgent(ownerAddr)

        const status = await amgr.getStatus(ownerAddr);
        expect(status).to.be.eq(1n);
        log("Super registered")
        
        // rotator imitation
        const rotatorRole = await amgr.ROTATOR()
        await amgr.grantRole(rotatorRole, owner.address)
        for (let i = 1; i < 10; i++) {
            const addr = await signers[i].getAddress()

            await agrgr.registerAgentOneKeyEVM(1, addr);

            await amgr.activateAgents([addr])

            const status = await amgr.getStatus(addr);
            expect(status).to.be.eq(1n);
            agents.push(signers[i]);
            log(`Agent ${i} created: ${signers[i].address}`)
        }

        const amgrFromMaster = await master.agentManager();
        expect(amgrFromMaster).to.be.eq(await amgr.getAddress())

        const role = await md.PRESERVER();
        const hasRole = await md.hasRole(role, await master.getAddress());
        expect(hasRole).to.be.true
    });

    it("Should transmit proposal", async function () {
        // sign message and send it to master
        const coder = ethers.AbiCoder.defaultAbiCoder();

        const opData = await getTestMsg();
        let signature = await signSolo(agent1, opData);
        log("Signature struct:", signature)
        log(`Signature decomposited: ${signature.v}, ${signature.r}, ${signature.s}`)

        let tx;
        const rawOpData = await getTestRawMsg()
        log("Sending with agent1", await agent1.getAddress(), "to master", await master.getAddress())
        
        // impossible without turn round operation before. check master::consensusRates()
        tx = await master.connect(agent1).addTransmissionSignatureBatch([opData.initialProposal], [rawOpData.srcChainData], [signature])
        await tx.wait()

        // check master statuses
        // 

        // const chainDataHash = await getChainDataHash(opData.srcChainData);                   -- master store prefixed hash as a key in msgConsensusData and msgExecutionData
        const prefixedMsg = await getPrefixedMsg(opData)
        log("Chain data hash: ", prefixedMsg)
        const signed = await master.isMessageSigned(prefixedMsg, await agent1.getAddress());
        log("Signed status after adding: ", prefixedMsg)
        const consensusData = await master.msgConsensusData(prefixedMsg);                                          
        log("Consensus data: ", consensusData)
        let siglen = await master.getTSignatures(prefixedMsg);

        expect(signed).to.be.true
        expect(consensusData).to.be.eq(await agent1.getAddress()) // first proposer
        expect(siglen.length).to.be.eq(1n)
    })
})


