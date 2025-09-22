import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import {
    TokenMock__factory,
    TokenMock, Rotator,
    AgentManager,
    AgentRegistrator,
    KeyStorage,
    Endpoint,
    RewardVaults,
    ChainInfo,
    PingSystem,
    FeeCalculator,
    PointDistributor,
    WToken,
    Slasher,
    MessageData,
    Master,
    ExecutorLottery,
    DFAdapter,
    DFOracleMock,
    Rewards,
    Staking
} from "../typechain-types";

import hre, { ethers, upgrades } from "hardhat";
import { main as deployMC } from "../scripts/deploy/assembled/deployMC"
import { loadDeploymentAddress } from "../utils/fileUtils";
import { BigNumberish, BytesLike } from "ethers";
import { expect } from "chai";
import { getPrefixedMsg, getTestMsg, getTestRawMsg, signConsensus, signSolo } from "./testUtils";
import { TEST_DEST_CHAIN_ID } from "../utils/constants";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { mine } from "@nomicfoundation/hardhat-network-helpers";

const chainID = 1;

async function deployWToken() {
    const tokenFactory: TokenMock__factory = await ethers.getContractFactory("TokenMock");
    const token = await tokenFactory.deploy();
    await token.waitForDeployment()

    return token as unknown as TokenMock;
}

describe("Full stacking", function() {
    this.timeout(600000)

    let registrator: AgentRegistrator;
    let keyStorage: KeyStorage;
    let agentManager: AgentManager;
    let rotator: Rotator;
    let feeCalculator: FeeCalculator;
    let pointDistributor: PointDistributor
    let rewards: Rewards
    let wToken: WToken;
    let slasher: Slasher
    let messageData: MessageData
    let pingSystem: PingSystem
    let chainInfo: ChainInfo
    let lottery: ExecutorLottery;
    let DFAdapter: DFAdapter;
    let DFOracle: DFOracleMock;
    let staking: Staking;

    let owner: HardhatEthersSigner;
    let transmitters: HardhatEthersSigner[]
    let executors: HardhatEthersSigner[]
    let superAgent: HardhatEthersSigner;
    let master: Master;
    let signers: HardhatEthersSigner[];
    let msg: any;
    let msgRaw: any;
    let msgHash: BytesLike;
    let transmittersSigs: any;
    let pureAgentSigs: any;
    let executorSigs: any;
    let pureExecutorSigs: any;

    const baseChainId = 31337
    const testChainId = 1
    const coder = ethers.AbiCoder.defaultAbiCoder();
    const pendingTxDestHashes: [BytesLike, BytesLike] = [ethers.randomBytes(32), ethers.randomBytes(32),]

    before(async() => {
        signers = await hre.ethers.getSigners()
        owner = signers[0]
        transmitters = signers.slice(1, 4)
        executors = signers.slice(4, 7)
        superAgent = signers[8]

        await deployMC()

        const registratorAddr = loadDeploymentAddress("hardhat", "AgentRegistrator")
        registrator = await ethers.getContractAt("AgentRegistrator", registratorAddr, owner)
        
        const keyStorageAddr = loadDeploymentAddress("hardhat", "KeyStorage")
        keyStorage = await ethers.getContractAt("KeyStorage", keyStorageAddr, owner)
        
        const rotatorAddr = loadDeploymentAddress("hardhat", "Rotator")
        rotator = await ethers.getContractAt("Rotator", rotatorAddr, owner)

        const pingSystemAddr = loadDeploymentAddress("hardhat", "PingSystem");
        pingSystem = await ethers.getContractAt("PingSystem", pingSystemAddr, owner);
        
        const mngrAddr = loadDeploymentAddress("hardhat", "AgentManager")
        agentManager = await ethers.getContractAt("AgentManager", mngrAddr, owner)
        
        const feeCalculatorAddr = loadDeploymentAddress("hardhat", "FeeCalculator")
        feeCalculator = await ethers.getContractAt("FeeCalculator", feeCalculatorAddr, owner)
        
        const pointDistributorAddr = loadDeploymentAddress("hardhat", "PointDistributor")
        const DFAdapterAddr = loadDeploymentAddress("hardhat", "DFAdapter");
        pointDistributor = await ethers.getContractAt("PointDistributor", pointDistributorAddr, owner)
        await pointDistributor.setDFAdapter(DFAdapterAddr);

        const wTokenF = await ethers.getContractFactory("WToken")
        wToken = await wTokenF.deploy()
        
        const rewardsAddr = loadDeploymentAddress("hardhat", "Rewards")
        rewards = await ethers.getContractAt("Rewards", rewardsAddr, owner)
        // await rewards.setWNGL(await wngl.getAddress())
        
        const slasherAddr = loadDeploymentAddress("hardhat", "Slasher")
        slasher = await ethers.getContractAt("Slasher", slasherAddr, owner)
        await slasher.setSlashValue(10)
        
        const messageDataAddr = loadDeploymentAddress("hardhat", "MessageData")
        messageData = await ethers.getContractAt("MessageData", messageDataAddr, owner)
        
        const masterAddr = loadDeploymentAddress("hardhat", "Master")
        master = await ethers.getContractAt("Master", masterAddr, owner)
        
        const chainInfoAddr = loadDeploymentAddress("hardhat", "ChainInfo")
        chainInfo = await ethers.getContractAt("ChainInfo", chainInfoAddr, owner)

        const lotteryAddr = loadDeploymentAddress("hardhat", "ExecutorLottery")
        lottery = await ethers.getContractAt("ExecutorLottery", lotteryAddr, owner)

        const stakingAddr = loadDeploymentAddress("hardhat", "Staking")
        staking = await ethers.getContractAt("Staking", stakingAddr, owner)

        DFAdapter = await ethers.getContractAt("DFAdapter", DFAdapterAddr, owner);
        const DFOracleAddr = loadDeploymentAddress("hardhat", "DFOracleMock");
        DFOracle = await ethers.getContractAt("DFOracleMock", DFOracleAddr, owner);
        await DFAdapter.setDFOracle(DFOracleAddr);
        await DFAdapter.setChainInfo(chainInfoAddr);

        const random_oracle = coder.encode(
            ["address"],
            [ethers.ZeroAddress]
        )
        await chainInfo.connect(owner).setChainInfo(
            1,           
            "0x0000000000000000000000000000000000000001", 
            "0x4554482f55534400000000000000000000000000000000000000000000000000",
            18,
            "Ethereum Sepolia",     
            "ETH",  
            "https://sepolia.gateway.tenderly.co",      
            "0x00000000000000000000000094c78fbf9e269c1ef8ae41c66f961c5f283ef623",   
            "0x00000000000000000000000094c78fbf9e269c1ef8ae41c66f961c5f283ef623",   
            random_oracle,
        )

        await chainInfo.connect(owner).setChainInfo(
            TEST_DEST_CHAIN_ID,           
            "0x0000000000000000000000000000000000000001", 
            "0x4d4e542f55534400000000000000000000000000000000000000000000000000",
            9,
            "Solana",     
            "SOL",  
            "https://sepolia.gateway.tenderly.co",      
            "0x00000000000000000000000094c78fbf9e269c1ef8ae41c66f961c5f283ef623",   
            "0x00000000000000000000000094c78fbf9e269c1ef8ae41c66f961c5f283ef623",   
            random_oracle,
        )

        await DFAdapter.setDataKeyToChain(1, "0x4554482f55534400000000000000000000000000000000000000000000000000");
        await DFAdapter.setDataKeyToChain(TEST_DEST_CHAIN_ID, "0x4d4e542f55534400000000000000000000000000000000000000000000000000");
        await DFOracle.setLatestUpdate("0x4554482f55534400000000000000000000000000000000000000000000000000", 1000000000000000000n);
        await DFOracle.setLatestUpdate("0x4d4e542f55534400000000000000000000000000000000000000000000000000", 1000000000000000000n);

        await master.setContracts([
            pointDistributorAddr,
            DFAdapterAddr,
            mngrAddr,
            messageDataAddr,
            lotteryAddr,
            feeCalculatorAddr,
            keyStorageAddr,
            chainInfoAddr,
            rewardsAddr
        ]);
        await pingSystem.setKeyStorage(keyStorageAddr);
        await agentManager.setRotator(await rotator.getAddress())
        await rotator.setAgentManager(mngrAddr);
        await rotator.setKeyStorage(keyStorageAddr);
        await rotator.setChainInfo(chainInfoAddr);
        await rotator.setMaxPercentChange(5000);
        await registrator.setAgentManager(mngrAddr);
        await agentManager.setPingSystem(pingSystemAddr);
        await chainInfo.grantRole(await chainInfo.SETTER(), rotatorAddr)
        await chainInfo.setChainParams(TEST_DEST_CHAIN_ID, 200, 100)
        await slasher.setAgentManager(mngrAddr)
        await slasher.setRewards(rewardsAddr)
        await slasher.setPingSystem(pingSystemAddr)
        await rewards.setStaking(stakingAddr)
        await staking.setWNative(wToken.target)
        await staking.setRewardsContract(rewardsAddr)
        await staking.setAgentManager(mngrAddr)
        await staking.setRotator(rotatorAddr)
        await lottery.setAgentManager(mngrAddr)
        await lottery.setMessageData(messageDataAddr)
    })

        
    describe("Agent Registrator", function() {

        it("should register agent", async function () {
            transmitters.map(async (agent) => {
                let keys: BytesLike[] = [];
                for (let i = 0; i < 4; i++) {
                    keys[i] = coder.encode(
                        ["address"],
                        [agent.address]
                    )
                }

                await registrator.registerAgent(baseChainId, agent.address, keys)

                const agentInfo = await agentManager.allAgents(agent.address);
                expect(agentInfo.status).to.be.eq(1n);
            })
        });

        it("should register executors", async function () {
            executors.map(async (agent) => {
                let keys: BytesLike[] = [];
                for (let i = 0; i < 4; i++) {
                    keys[i] = coder.encode(
                        ["address"],
                        [agent.address]
                    )
                }

                await registrator.registerAgent(testChainId, agent.address, keys)

                const agentInfo = await agentManager.allAgents(agent.address);
                expect(agentInfo.status).to.be.eq(1n);
            })
        });

        it("should revert if registering agent with zero address", async function () {
            await expect(registrator.registerAgentOneKeyEVM(1, ethers.ZeroAddress))
              .to.be.revertedWithCustomError(registrator, "Registrator__InvalidAgentAddress");
        });

        it("should revert if registering the same agent twice", async function () {        
            await expect(registrator.registerAgentOneKeyEVM(1, transmitters[0].address))
              .to.be.revertedWithCustomError(registrator, "Registrator__AlreadyRegistered");
        });
                
        it ("Should allow transmitters to stake",async function() {
            const wToken = await deployWToken();
            // await rewardVaults.setWNGL(await wngl.getAddress());

            await expect(staking.deposit(transmitters[0].address, 0, { 
                value: 1000
            })).to.emit(staking, "Deposit").withArgs(
                baseChainId, transmitters[0].address, owner.address, 1000
            );
        });

        it("should register super agent", async function () {
            const agentAddr = superAgent.address
            let keys: BytesLike[] = [];
            for (let i = 0; i < 4; i++) {
                keys[i] = coder.encode(
                    ["address"],
                    [agentAddr]
                )
            }

            await registrator.registerSuperAgent(agentAddr, keys)
            
            const agentInfo = await agentManager.allAgents(agentAddr);
            expect(agentInfo.status).to.be.eq(2n);

            await agentManager.forceRegisterSuperAgent(agentAddr)

            const num = await agentManager.activeSupersAddr(0);
            expect(num.length).to.be.eq(1n);
        });

        it("should activate super agent", async function () {
            const agentAddr = superAgent.address

            await agentManager.forceRegisterSuperAgent(agentAddr)
            
            expect(await agentManager.getStatus(agentAddr)).to.be.eq(1n);
        });
        
    });

    describe("Turn round", function() {

        it ("Should turn round source network if conditions are met", async function() {
            await mine(100)

            for (let i = 0; i < transmitters.length; i++) {
                await staking.connect(transmitters[i]).deposit(transmitters[i].address, 0, { value: 120 * 10**5 });
                await pingSystem.connect(transmitters[i]).ping();
            }            
            
            await rotator.setDefaultMinimalDuration(100);
            await rotator.changeRound(baseChainId, { value: 1 });
        });

        it ("Should turn round destination network if conditions are met", async function() {
            await mine(100)

            for (let i = 0; i < executors.length; i++) {
                await staking.connect(executors[i]).deposit(executors[i].address, 0, { value: 120 * 10**5 });
                await pingSystem.connect(executors[i]).ping();
            }            
            
            await rotator.setDefaultMinimalDuration(100);
            await rotator.changeRound(testChainId, { value: 1 });
        });

        it ("Should not turn round when coodown", async function() {
            const block = await ethers.provider.getBlock('latest')
            await rotator.setDefaultMinimalDuration(block!.timestamp + 1000);
            await expect(rotator.changeRound(baseChainId)).to.be.revertedWithCustomError(rotator, "Rotator__ShouldWaitFor");
        });

        it ("Can turn round after cooldown but does nothing without candidates", async function() {
            await rotator.setDefaultMinimalDuration(1);
            expect(await rotator.changeRound(baseChainId)).to.emit(
                rotator, "NoPending"
            ).withArgs(baseChainId);
        });

    });

    describe("Message processing", function() {
        let msgExecutor: BytesLike

        it("should create message and transmitters should sign it", async function () {
            msg = await getTestMsg()
            msgRaw = await getTestRawMsg()
            msgHash = await getPrefixedMsg(msg)

            pureAgentSigs = await signConsensus(transmitters, msg)
            transmittersSigs = pureAgentSigs.map((sig: any) => {
                return ethers.Signature.from(sig)
            })

            pureExecutorSigs = await signConsensus(executors, msg)
            executorSigs = pureExecutorSigs.map((sig: any) => {
                return ethers.Signature.from(sig)
            });

            await messageData.grantRole(await messageData.PRESERVER(), owner);
            await messageData.storeMessage(msgHash, msg);
        })

        it("should revert if agent is not allowed", async function() {
            const _agents: HardhatEthersSigner[] = await ethers.getSigners()
            const sig = await signSolo(_agents[10], msg)

            await expect(
                master.connect(_agents[10]).addTransmissionSignatureBatch(
                    [msgRaw.initialProposal],
                    [msgRaw.srcChainData],
                    [sig]
                )
            ).to.be.revertedWithCustomError(master, "Master__InvalidKey")
        })

        it("transmitters should add sigs", async function () {
            for (let i = 0; i < transmitters.length; i++) {
                transmittersSigs[i] = await signSolo(transmitters[i], msg);
                await master.connect(transmitters[i]).addTransmissionSignatureBatch(
                    [msg.initialProposal], 
                    [msgRaw.srcChainData], 
                    [transmittersSigs[i]]
                );
                expect(await master.isMessageSigned(msgHash, transmitters[i].address)).to.be.eq(true)
            }
        })

        it("super should add sig", async function () {
            const superSig = await signSolo(superAgent, msg)

            await messageData.changeMessageStatus(msgHash, 3);

            await master.connect(superAgent).addExecutionSignatureBatch(
                [msgHash],
                [superSig]
            )
            expect(await master.approvedBySuper(msgHash, superAgent.address)).to.be.eq(true)
        })

        it("executors should add sigs", async function () {
            for (let i = 0; i < executors.length; i++) {
                console.log(msgHash, executorSigs[i])
                await master.connect(executors[i]).addExecutionSignatureBatch([msgHash], [executorSigs[i]])
                expect(await master.isMessageSigned(msgHash, executorSigs[i].address)).to.be.eq(true)
            }

            expect(await messageData.getMsgStatusByHash(msgHash)).to.be.eq(4)

        })


        it("super agent should send execution assigment", async function () {
            await master.connect(superAgent).sendNewExecutionAssignment(msgHash)
        })

        it("should add pending tx", async function () {
            await time.increase(100)
            const curExecutorAddr = await lottery.currentExecutorAgent(msgHash)
            console.log("cur executor addr: ", curExecutorAddr)
            // const _executors = (await ethers.getSigners()).slice(4,7)
            
            for (let i = 0; i < executors.length; i++) {
                if (executors[i].address == curExecutorAddr) {
                    msgExecutor = coder.encode(["address"], [executors[i].address])
                    console.log("msg executor: ", msgExecutor)
                    // console.log("found executor in list ", _executors[i].address)
                    // const destHash: [BytesLike, BytesLike] = [ethers.randomBytes(32), ethers.randomBytes(32)]
                    const addrBytes: BytesLike = coder.encode(
                        ["address"],
                        [curExecutorAddr]
                    )
                    console.log("addr bytes: ", addrBytes)
                    console.log("msg hash: ", msgHash)
                    console.log("pending dest hashes: ", pendingTxDestHashes)
                    await master.connect(executors[i]).addPendingTx(msgHash, pendingTxDestHashes, addrBytes)
                    
                    // console.log("call successful")
                    break
                } 
            }

            expect(await messageData.getMsgStatusByHash(msgHash)).to.be.eq(5)
        })

        it("should approve message delivery", async function () {
            const newStatus: BigNumberish = 12n

            await master.connect(superAgent).approveMessageDeliveryBatch([msgHash], [newStatus], [msg.initialProposal.nativeAmount], [pendingTxDestHashes], [msgExecutor] )            
            expect(await messageData.getMsgStatusByHash(msgHash)).to.be.eq(12)
        })

    })

    describe("Slasher", async function () {
        it("should revert if slash zero address", async function () {
            await expect(slasher.slash(ethers.ZeroAddress)).to.be.revertedWithCustomError(slasher, "SLASHER__ZeroAddress")
        })

        it("should revert if slash agent with zero stake", async function () {
            await expect(slasher.slash(superAgent.address)).to.be.revertedWithCustomError(slasher, "SLASHER__AgentNotSlashable")
        })

        it("should slash agent", async function () {
            await time.increase(100)
            const _agents = (await ethers.getSigners()).slice(1,4)
            // await pingSystem.connect(_agents[0]).ping();
            await slasher.setSlashValue(100)

            await slasher.slash(_agents[0].address)

            expect(await rewards.vaultSelfStake(baseChainId, _agents[0].address)).to.be.eq(20)
        })

        it("should revert if agent slashed a couple of times in a row", async function () {
            const _agents = (await ethers.getSigners()).slice(1,4)
            await expect(slasher.slash(_agents[0].address)).to.be.revertedWithCustomError(slasher, "SLASHER__AgentNotSlashable")
        });

        it("Should revert if agent is active", async function() {
            const _agents = (await ethers.getSigners()).slice(1,4)
            await pingSystem.connect(_agents[1]).ping();
            
            await expect(slasher.slash(_agents[1].address)).to.be.revertedWithCustomError(slasher, "SLASHER__AgentNotSlashable");
        });

        it("should slash all agent stake if its less than slash value", async function () {
            await time.increase(100)
            const _agents = (await ethers.getSigners()).slice(1,4)
            // await pingSystem.connect(_agents[1]).ping();
            await slasher.setSlashValue(200)
            await slasher.slash(_agents[2].address)

            expect(await rewards.vaultSelfStake(baseChainId, _agents[2].address)).to.be.eq(0)
        });
    });
})