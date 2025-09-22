import { ethers } from "hardhat";
import { Wallet } from "ethers";
import { PingSystem, KeyStorage } from "../typechain-types";
import { deployKeyStorageFixture, deployPingSystemFixture } from "./deploymentFixtures";
import { expect } from "chai";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("PingSystem", function() {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;
    let agent: HardhatEthersSigner;
    let agent2: HardhatEthersSigner;
    let badActor: HardhatEthersSigner;

    let pingSystem: PingSystem;
    let keyStorage: KeyStorage;

    const keyTypes = [0, 1, 2, 3];
    let agentKey: string;
    let agent2Key: string;
    const chainId = 1
    const THRESHOLD = 7200;

    before(async () => {        
        signers = await ethers.getSigners();
        owner = signers[0];
        agent = signers[1];
        agent2 = signers[2];
        badActor = signers[3];

        keyStorage = await deployKeyStorageFixture()
        pingSystem = await deployPingSystemFixture();

        await pingSystem.setKeyStorage(keyStorage.target);
    });

    it("Should initialize correctly", async function() {
        expect(await pingSystem.threshold()).to.equal(THRESHOLD);
        expect(await pingSystem.keyStorage()).to.equal(keyStorage.target);
    });

    it("Key Storage: should add keys", async function () {
        agentKey = ethers.AbiCoder.defaultAbiCoder().encode(["address"], [agent.address]);
        await keyStorage.connect(agent).addKey(chainId, keyTypes[0], agentKey);
        expect(await keyStorage.hasKeys(agent.address, chainId, keyTypes)).to.be.eq(true);
        expect(await keyStorage.ownerByKey(agentKey)).to.be.eq(agent.address);
    });

    it("should allow an agent to ping", async function () {
        await expect(pingSystem.connect(agent).ping())
            .to.emit(pingSystem, "Ping")
            .withArgs(agent.address);
    
        const lastPingTime = await pingSystem.lastPingTime(agent.address);
        expect(lastPingTime).to.be.closeTo((await ethers.provider.getBlock("latest")).timestamp, 2);
    });
    
    it("should revert if agent is not found", async function () {
        await expect(pingSystem.connect(badActor).ping()).to.be.revertedWithCustomError(
            pingSystem,
            "Ping__AgentNotFoundFor"
        );
    });

    it("should correctly track last ping time", async function () {
        const tx = await pingSystem.connect(agent).ping();
        const blockTimestamp = (await ethers.provider.getBlock(tx.blockNumber || 0)).timestamp;

        const lastPingTime = await pingSystem.lastPingTime(agent.address);
        expect(lastPingTime).to.eq(blockTimestamp);
    });

    it("should correctly check agent activity", async function () {
        await pingSystem.connect(agent).ping();

        expect(await pingSystem.active(agent.address)).to.eq(true);

        await time.increase(THRESHOLD * 10)
        
        expect(await pingSystem.active(agent.address)).to.eq(false);
    });

    it("should return active agents in a batch", async function () {
        agent2Key = ethers.AbiCoder.defaultAbiCoder().encode(["address"], [agent2.address]);
        await keyStorage.connect(agent2).addKey(chainId, keyTypes[0], agent2Key);
        expect(await keyStorage.hasKeys(agent2.address, chainId, keyTypes)).to.be.eq(true);
        expect(await keyStorage.ownerByKey(agent2Key)).to.be.eq(agent2.address);

        await pingSystem.connect(agent).ping();
        await pingSystem.connect(agent2).ping();

        const agents = [agent.address, agent2.address];
        const activeAgents = await pingSystem.activeBatch(agents);

        expect(activeAgents).to.deep.equal([true, true]);
    });

    it("should only return active agents in activeOnly", async function () {
        await pingSystem.connect(agent).ping();

        await ethers.provider.send("evm_increaseTime", [THRESHOLD + 1]);
        await ethers.provider.send("evm_mine", []);

        await pingSystem.connect(agent2).ping();

        const agents = [agent.address, agent2.address];

        const activeOnlyAgents = await pingSystem.activeOnly(agents);
        expect(activeOnlyAgents.toString()).to.equal([agent2.address].toString());
    });

    it("should allow only admin to update the Key Storage", async function () {
        const randomWallet = Wallet.createRandom();
        const randomAddress = randomWallet.address;
        const newKeyStorageAddress = randomAddress;

        await pingSystem.connect(owner).setKeyStorage(newKeyStorageAddress);
        expect(await pingSystem.keyStorage()).to.eq(newKeyStorageAddress);
        
        await expect(
            pingSystem.connect(agent).setKeyStorage(newKeyStorageAddress)
        ).to.be.revertedWithCustomError(pingSystem, "AccessControlUnauthorizedAccount")
            .withArgs(agent.address, await pingSystem.ADMIN());
    });

    it("should revert if new Key Storage address is set to zero", async function () {
        await expect(pingSystem.connect(owner).setKeyStorage(ethers.ZeroAddress)).to.be.revertedWithCustomError(
            pingSystem,
            "Ping__InvalidAddress"
        );
    });    

    it("should allow only admin to update the threshold", async function () {
        const newThreshold = 20;

        await expect(pingSystem.connect(owner).setTimingThreshold(newThreshold))
            .to.emit(pingSystem, "ThresholdChanged")
            .withArgs(THRESHOLD, newThreshold);

        expect(await pingSystem.threshold()).to.eq(newThreshold);

        await expect(
            pingSystem.connect(agent).setTimingThreshold(newThreshold)
        ).to.be.revertedWithCustomError(pingSystem, "AccessControlUnauthorizedAccount")
            .withArgs(agent.address, await pingSystem.ADMIN());
    });

    it("should revert if threshold is set to zero", async function () {
        await expect(pingSystem.connect(owner).setTimingThreshold(0)).to.be.revertedWithCustomError(
            pingSystem,
            "Ping__InvalidThreshold"
        );
    });    

});