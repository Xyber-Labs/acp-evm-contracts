import { ethers } from "hardhat";
import { 
    Rotator,
    AgentManager,
    AgentRegistrator,
    RewardVaults,
    KeyStorage,
    ChainInfo,
    Endpoint,
    PingSystem,
    WToken,
    Rewards,
    Staking,
    GasEstimator,
    DFOracleMock
} from "../typechain-types";
import { deployMC } from "./deploymentFixtures";
import { expect } from "chai";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { log } from "./testLogger";
import { loadDeploymentAddress } from "../utils/fileUtils";

describe("Rotator", function() {
    this.timeout(600000)

    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;

    let agents: HardhatEthersSigner[];

    let rotator: Rotator;
    let agentManager: AgentManager;
    let agentRegistrator: AgentRegistrator;
    let rewards: Rewards;
    let keyStorage: KeyStorage;
    let chainInfo: ChainInfo;
    let endpoint: Endpoint;
    let pingSystem: PingSystem;
    let wToken: WToken;
    let staking: Staking
    let estimator: GasEstimator
    let oracle: DFOracleMock

    const CHAIN_ID = 31337n;
    const MIN_SLOTS = 3;
    const MAX_SLOTS = 16;  
    const DATA_KEY = ethers.randomBytes(32)
    const GAS_DATA_KEY = ethers.randomBytes(32)

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];
        agents = signers.slice(1,);

        await deployMC();

        const rotatorAddress = loadDeploymentAddress("hardhat", "Rotator");
        rotator = await ethers.getContractAt("Rotator", rotatorAddress, owner);

        const rewardsAddress = loadDeploymentAddress("hardhat", "Rewards");
        rewards = await ethers.getContractAt("Rewards", rewardsAddress, owner);

        const stakingAddress = loadDeploymentAddress("hardhat", "Staking")
        staking = await ethers.getContractAt("Staking", stakingAddress, owner)

        // const rewardVaultsAddress = loadDeploymentAddress("hardhat", "RewardVaults");
        // rewardVaults = await ethers.getContractAt("RewardVaults", rewardVaultsAddress, owner);

        const keyStorageAddress = loadDeploymentAddress("hardhat", "KeyStorage");
        keyStorage = await ethers.getContractAt("KeyStorage", keyStorageAddress, owner);

        const chainInfoAddress = loadDeploymentAddress("hardhat", "ChainInfo");
        chainInfo = await ethers.getContractAt("ChainInfo", chainInfoAddress, owner);

        const endpointAddress = loadDeploymentAddress("hardhat", "Endpoint");
        endpoint = await ethers.getContractAt("Endpoint", endpointAddress, owner);

        const managerAddress = loadDeploymentAddress("hardhat", "AgentManager");
        agentManager = await ethers.getContractAt("AgentManager", managerAddress, owner);

        const agentRegistratorAddress = loadDeploymentAddress("hardhat", "AgentRegistrator");
        agentRegistrator = await ethers.getContractAt("AgentRegistrator", agentRegistratorAddress, owner);

        const pingSystemAddress = loadDeploymentAddress("hardhat", "PingSystem");
        pingSystem = await ethers.getContractAt("PingSystem", pingSystemAddress, owner);

        const estimatorAddress = loadDeploymentAddress("hardhat", "GasEstimator")
        estimator = await ethers.getContractAt("GasEstimator", estimatorAddress, owner)

        const oracleAddress = loadDeploymentAddress("hardhat", "DFOracleMock")
        oracle = await ethers.getContractAt("DFOracleMock", oracleAddress, owner)

        await rotator.setAgentManager(managerAddress);
        await rotator.setRewards(rewardsAddress)
        await rotator.setStaking(stakingAddress)
        // await rotator.setRewardVaults(rewardVaultsAddress);
        await rotator.setKeyStorage(keyStorageAddress);
        await rotator.setChainInfo(chainInfoAddress);
        await rotator.setEndpoint(endpointAddress);

        await rotator.setDefaultMinimalDuration(3600);
        await rotator.setMaxPercentChange(2500);

        await chainInfo.setChainInfo(
            CHAIN_ID,
            owner.address,
            ethers.ZeroHash,
            18,
            "testChain",
            "TST",
            "",
            ethers.ZeroHash,
            ethers.ZeroHash,
            ethers.ZeroHash
        );

        await pingSystem.setTimingThreshold(100);

        const wTokenF = await ethers.getContractFactory("WToken");
        wToken = await wTokenF.deploy();
        
        await rewards.setStaking(stakingAddress)
        await staking.setWNative(wToken.target);

        await estimator.setDFOracle(oracleAddress)
        await estimator.setChainData(CHAIN_ID, {
            totalFee: 10n,
            decimals: 18n,
            defaultGas: 10,
            gasDataKey: GAS_DATA_KEY,
            nativeDataKey: DATA_KEY
        })
        
        await oracle.setLatestUpdate(DATA_KEY, 10)
        await oracle.setLatestUpdate(GAS_DATA_KEY, 20)

        await endpoint.setTotalActiveSigners(3)
    });

    it("should sort account stakes", async function() {
        // get first 6 signers 
        const signers = await ethers.getSigners();
        const firstSix = signers.slice(1, 7);
        const firstSixAddrs = firstSix.map(s => s.address)
        log("signer addresses non sorted", firstSixAddrs)

        const accountStakes = [
            {
                agent: signers[1].address, // 1
                stake: 10
            },
            {

                agent: signers[2].address, // 0
                stake: 11
            },
            {

                agent: signers[3].address, // 5
                stake: 1
            },
            {

                agent: signers[4].address, // 3
                stake: 7
            },
            {
                agent: signers[5].address, // 4
                stake: 6
            },
            {
                agent: signers[6].address, // 2
                stake: 8
            }
        ]

        const sorted = await rotator.sortStakes(accountStakes)
        log("Sorted", sorted)

        expect(sorted[0]).to.be.eq(signers[2].address)
        expect(sorted[1]).to.be.eq(signers[1].address)
        expect(sorted[2]).to.be.eq(signers[6].address)
        expect(sorted[3]).to.be.eq(signers[4].address)
        expect(sorted[4]).to.be.eq(signers[5].address)
        expect(sorted[5]).to.be.eq(signers[3].address)
    })

    it("should estimate slot change", async function() {
        // no override
        const chainID = 1
        let open = 0
        let agents = 6

        let estimation = await rotator.estimateSlotChange(chainID, agents, open)
        log("Estimation", estimation)
        expect(estimation[0]).to.be.eq(1n)
        expect(estimation[1]).to.be.eq(0n)

        agents = 8
        estimation = await rotator.estimateSlotChange(chainID, agents, open)
        log("Estimation", estimation)
        expect(estimation[0]).to.be.eq(2n)
        expect(estimation[1]).to.be.eq(0n)

        agents = 8
        open = 1 
        estimation = await rotator.estimateSlotChange(chainID, agents, open)
        log("Estimation", estimation)
        expect(estimation[0]).to.be.eq(1n)
        expect(estimation[1]).to.be.eq(1n)
    })

    it("should mix addresses", async function() {
        let change = 2
        let open = 0
        let close = 0


        // first 8 signers addresses
        const signers = await ethers.getSigners();
        const firstEight = signers.slice(1, 9);
        const firstEightAddrs = firstEight.map(s => s.address)

        //  8-12 
        const next = signers.slice(9, 13)
        const nextAddr = next.map(s => s.address)
        

        let agents = firstEightAddrs
        let candidates = nextAddr

        log("agents", agents)
        log("candidates", candidates)

        let mix = await rotator.mixAgents(
            agents,
            candidates,
            change, 
            open,
            close
        )
        log("mix1", mix)

        // expect(mix[mix.length - 1]).to.be.eq(candidates[1])
        // expect(mix[mix.length - 2]).to.be.eq(candidates[0])

        change = 1
        open = 1
        close = 0
        mix = await rotator.mixAgents(
            agents,
            candidates,
            change,
            open,
            close
        )
        log("mix2", mix)
        // expect(mix[mix.length - 1]).to.be.eq(candidates[1])
        // expect(mix[mix.length - 2]).to.be.eq(candidates[0])
        // expect(mix.length - agents.length).to.be.eq(1)

        change = 0
        open = 0
        close = 2
        mix = await rotator.mixAgents(
            agents,
            candidates,
            change,
            open,
            close
        )
        log("mix3", mix)
        // expect(agents.length - mix.length).to.be.eq(2)
    });

    it("Should initialize new network when the current round is 0", async function() {
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[0].address);
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[1].address);
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[2].address);

        await staking.connect(agents[0]).deposit(agents[0].address, 0, { value: ethers.parseEther("0.1") });
        await staking.connect(agents[1]).deposit(agents[1].address, 0, { value: ethers.parseEther("0.1") });
        await staking.connect(agents[2]).deposit(agents[2].address, 0, { value: ethers.parseEther("0.1") });

        await pingSystem.connect(agents[0]).ping();
        await pingSystem.connect(agents[1]).ping();
        await pingSystem.connect(agents[2]).ping();

        await rotator.changeRound(CHAIN_ID);
        expect(await rotator.currentRound(CHAIN_ID)).to.be.equal(1);
    });

    it("Should change round after minimum duration", async function() {
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[3].address);
        await expect(rotator.changeRound(CHAIN_ID)).to.be.revertedWithCustomError(rotator, "Rotator__ShouldWaitFor");

        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");

        await pingSystem.connect(agents[0]).ping();
        await pingSystem.connect(agents[1]).ping();
        await pingSystem.connect(agents[2]).ping();
        await pingSystem.connect(agents[3]).ping();
 
        await staking.connect(agents[3]).deposit(agents[3].address, 0, { value: ethers.parseEther("0.1") });

        await rotator.changeRound(CHAIN_ID, { value: ethers.parseEther("0.001") });
        expect(await rotator.currentRound(CHAIN_ID)).to.equal(2);

        const participants = await agentManager.getCurrentParticipants(CHAIN_ID);
        const agentsAddresses = [agents[0].address, agents[1].address, agents[2].address, agents[3].address];
        expect(participants).to.be.deep.equal(agentsAddresses);
    });

    it("Should expand slots when free slots available", async function() {
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[4].address);
        await staking.connect(agents[4]).deposit(agents[4].address, 0, { value: ethers.parseEther("0.1") });

        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[5].address);
        await staking.connect(agents[5]).deposit(agents[5].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[6].address);
        await staking.connect(agents[6]).deposit(agents[6].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[7].address);
        await staking.connect(agents[7]).deposit(agents[7].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[8].address);
        await staking.connect(agents[8]).deposit(agents[8].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[9].address);
        await staking.connect(agents[9]).deposit(agents[9].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[10].address);
        await staking.connect(agents[10]).deposit(agents[10].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[11].address);
        await staking.connect(agents[11]).deposit(agents[11].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[12].address);
        await staking.connect(agents[12]).deposit(agents[12].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[13].address);
        await staking.connect(agents[13]).deposit(agents[13].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[14].address);
        await staking.connect(agents[14]).deposit(agents[14].address, 0, { value: ethers.parseEther("0.1") });
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[15].address);
        await staking.connect(agents[15]).deposit(agents[15].address, 0, { value: ethers.parseEther("0.1") });

        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");

        await pingSystem.connect(agents[0]).ping();
        await pingSystem.connect(agents[1]).ping();
        await pingSystem.connect(agents[2]).ping();
        await pingSystem.connect(agents[3]).ping();
        await pingSystem.connect(agents[4]).ping();
        await pingSystem.connect(agents[5]).ping();
        await pingSystem.connect(agents[6]).ping();
        await pingSystem.connect(agents[7]).ping();
        await pingSystem.connect(agents[8]).ping();
        await pingSystem.connect(agents[9]).ping();
        await pingSystem.connect(agents[10]).ping();
        await pingSystem.connect(agents[11]).ping();
        await pingSystem.connect(agents[12]).ping();
        await pingSystem.connect(agents[13]).ping();
        await pingSystem.connect(agents[14]).ping();
        await pingSystem.connect(agents[15]).ping();

        await rotator.changeRound(CHAIN_ID, { value: ethers.parseEther("0.001") });

        const newParticipants = await agentManager.getCurrentParticipants(CHAIN_ID);
        expect(newParticipants.length).to.equal(MAX_SLOTS);
        expect(newParticipants).to.include(agents[15].address);
    });

    it("Should close slots when exceeding slot limit", async function() {
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[16].address);

        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");

        await pingSystem.connect(agents[16]).ping();
        await staking.connect(agents[16]).deposit(agents[16].address, 0, { value: ethers.parseEther("0.1") });
        await rotator.changeRound(CHAIN_ID, { value: ethers.parseEther("0.001") });

        const newParticipants = await agentManager.getCurrentParticipants(CHAIN_ID);
        expect(newParticipants.length).to.equal(MAX_SLOTS);
        expect(newParticipants).to.include(agents[16].address);
        expect(newParticipants).to.not.include(agents[15].address);
    });

    it("Should replace lower-stake agents with higher-stake candidates", async function() {
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[17].address);
        await staking.connect(agents[17]).deposit(agents[17].address, 0, { value: ethers.parseEther("0.1") });

        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");

        await pingSystem.connect(agents[17]).ping();
        await rotator.changeRound(CHAIN_ID, { value: ethers.parseEther("0.001") });

        const newParticipants = await agentManager.getCurrentParticipants(CHAIN_ID);
        expect(newParticipants).to.include(agents[17].address);
        expect(newParticipants).to.not.include(agents[16].address);
    });

    it("Should allow early round change with force unlock", async function() {
        const roundBefore = await rotator.currentRound(CHAIN_ID);
        await staking.connect(agents[17]).withdraw(agents[17].address, ethers.parseEther("0.1"), true);
        await agentRegistrator.registerAgentOneKeyEVM(CHAIN_ID, agents[18].address);
        await pingSystem.connect(agents[18]).ping();

        await rotator.changeRound(CHAIN_ID, { value: ethers.parseEther("0.001") });
        expect(await rotator.currentRound(CHAIN_ID)).to.equal(roundBefore + 1n);
    });

    it("Should handle no pending candidates", async function() {
        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");

        const currentRound = await rotator.currentRound(CHAIN_ID);
        expect(await rotator.changeRound(CHAIN_ID)).to.emit(rotator, "NoPending");
        expect(await rotator.currentRound(CHAIN_ID)).to.be.equal(currentRound);
    });

    it("Should handle cannot expand scenario", async function () {
        expect(await rotator.changeRound(CHAIN_ID)).to.emit(rotator, "CannotExpand");
    });

    it("Should correctly revovle agents - Condition 1: Close Only", async function() {
        // Condition 1: Close Only

        const activeAgents = [agents[0].address, agents[1].address, agents[2].address, agents[3].address];
        const pendingCandidates = [agents[4].address, agents[5].address];

        await rotator.setMaxPercentChange(100000);
        await rotator.setSlotOverride(CHAIN_ID, 3);

        const res = await rotator.revolveAgents(CHAIN_ID, 3, activeAgents, pendingCandidates);
        expect(res[0].length).to.equal(3);
        expect(res[1].length).to.equal(0);
        expect(res[2].length).to.equal(1);
        expect(res[2]).to.deep.include(agents[3].address);
    });

    it("Should correctly revovle agents - Condition 2: Change Only", async function() {
        // Condition 2: Change Only

        const activeAgents = [agents[0].address, agents[1].address, agents[2].address];
        const pendingCandidates = [agents[3].address, agents[4].address];

        const res = await rotator.revolveAgents(CHAIN_ID, 0, activeAgents, pendingCandidates);
        expect(res[0].length).to.equal(activeAgents.length);
        expect(res[1].length).to.equal(pendingCandidates.length);
        expect(res[2].length).to.equal(pendingCandidates.length);
        expect(res[1]).to.deep.equal(pendingCandidates);
        expect(res[2]).to.deep.equal([agents[1].address, agents[2].address]);
    });

    it("Should correctly revovle agents - Condition 3: Open Only", async function() {
        // Condition 3: Open Only

        const activeAgents = [agents[0].address, agents[1].address, agents[2].address];
        const pendingCandidates = [agents[3].address, agents[4].address];

        const res = await rotator.revolveAgents(CHAIN_ID, 2, activeAgents, pendingCandidates);
        expect(res[0].length).to.equal(activeAgents.length + pendingCandidates.length);
        expect(res[1].length).to.equal(pendingCandidates.length);
        expect(res[2].length).to.equal(0);
        expect(res[1]).to.deep.equal(pendingCandidates);
    });

    it("Should correctly revovle agents - Condition 4: Open and Change", async function() {
        await rotator.setMaxPercentChange(5000);

        const activeAgents = [agents[0].address, agents[1].address, agents[2].address];
        const pendingCandidates = [agents[3].address, agents[4].address, agents[5].address, agents[6].address];

        const res = await rotator.revolveAgents(CHAIN_ID, 3, activeAgents, pendingCandidates);
        expect(res[1].length).to.be.not.equal(0);
        expect(res[2].length).to.be.not.equal(0);
    });
});