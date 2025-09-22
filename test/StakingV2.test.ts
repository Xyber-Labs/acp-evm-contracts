import { ethers, upgrades } from "hardhat";
import { ERC20Mock, ERC20Mock__factory, Rewards, Staking, WToken, AgentManagerMock, WToken__factory } from "../typechain-types";
import { log } from "./testLogger";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { chain } from "lodash";

async function deployRewardVaults(owner: any, stakingAddr: any) {
    const factory: any = await ethers.getContractFactory("Rewards");
    const instance = await upgrades.deployProxy(factory, 
        [[
            owner.address,
            stakingAddr
        ]], 
        {
            kind: "uups"
        }
    );
    await instance.waitForDeployment();

    return instance as unknown as Rewards;
}

async function deployStaking(owner: any) {
    const factory: any = await ethers.getContractFactory("Staking");

    const instance = await upgrades.deployProxy(factory, 
        [[
            owner.address,
        ]], 
        {
            kind: "uups"
        }
    );
    await instance.waitForDeployment();

    return instance as unknown as Staking;
}

async function deployWToken() {
    const wTokenFactory: WToken__factory = await ethers.getContractFactory("WToken");
    const wToken = await wTokenFactory.deploy();
    await wToken.waitForDeployment()

    return wToken as unknown as WToken;
}

async function deployTokenMock() {
    const tokenFactory: ERC20Mock__factory = await ethers.getContractFactory("ERC20Mock");
    const token = await tokenFactory.deploy();
    await token.waitForDeployment()

    return token as unknown as ERC20Mock;
}

async function deployAgentManagerMock() {
    const managerFactory = await ethers.getContractFactory("AgentManagerMock");
    const manager = await managerFactory.deploy();
    await manager.waitForDeployment();

    return manager as any;
}

describe("Staking V2", function() {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;

    let rw: Rewards;
    let staking: Staking;
    let rtoken: ERC20Mock; // reward ATS token for chain 1
    let rtoken2: ERC20Mock;
    let rtoken3: ERC20Mock;
    let wToken: any;
    let aManager: AgentManagerMock;

    let agent: HardhatEthersSigner;
    let agent2: HardhatEthersSigner;
    let dtor1: HardhatEthersSigner;
    let dtor2: HardhatEthersSigner;
    let dtor3: HardhatEthersSigner;

    const MIN_STAKE = ethers.parseEther("10");
    const STAKE = ethers.parseEther("1000");

    const DEFAULT_SHARE = 5000n;
    const FULL_SHARE = 10000n;

    const DEFAULT_REWARD = ethers.parseEther("1");
    const chainID = 1;

    let rewardsDtor1CheckPoint: bigint;
    let rewardsDtor2CheckPoint: bigint;
    let agentRewardsCheckPoint: bigint;

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];
        agent = signers[1];
        dtor1 = signers[2];
        dtor2 = signers[3];
        dtor3 = signers[4];
        agent2 = signers[5];

        staking = await deployStaking(owner);
        wToken = await deployWToken();
        rtoken = await deployTokenMock();
        rtoken2 = await deployTokenMock();
        rtoken3 = await deployTokenMock();
        rw = await deployRewardVaults(owner, await staking.getAddress());
        aManager = await deployAgentManagerMock();


        // setup 
        await staking.setWNative(await wToken.getAddress());
        await staking.setRewardsContract(await rw.getAddress());
        await staking.setCooldown(60n)
        await staking.setMinStake(MIN_STAKE)
        await staking.setTreasury(owner.address)
        await staking.setAgentManager(await aManager.getAddress())

        await rw.setReserve(owner.address)
        await rw.populateTokens(
            [chainID, 2n, 3n], 
            [
                await rtoken.getAddress(),
                await rtoken2.getAddress(), 
                await rtoken3.getAddress()
            ]
        )

        // fake owner as other contracts
        await rw.grantRole(await rw.SLASHER(), await owner.getAddress())
        await rw.grantRole(await rw.REWARDER(), await owner.getAddress())
        // grantRole to staking
        await rw.grantRole(await rw.STAKING(), await staking.getAddress())


        // grantRole to rewards to route slashing 
        await staking.grantRole(await staking.SLASHER(), await rw.getAddress())
        // make admin a depositor
        await staking.grantRole(await staking.DEPOSITOR(), await owner.getAddress())

        // check setup
        const stakingAddress = await rw.staking()
        expect(stakingAddress).to.be.equal(await staking.getAddress())

        const rewards = await staking.rewards()
        expect(rewards).to.be.equal(await rw.getAddress())
    })

    it("Should setup agent vaults", async function () {
        await staking.connect(agent).setRewardShare(DEFAULT_SHARE)
        const percent = await staking.getDelegationSharePercent(agent.address)
        expect(percent).to.be.eq(DEFAULT_SHARE)
    })


    it("Should deposit by agent", async function () {
        await staking.connect(agent).deposit(
            agent.address, 
            0, 
            {value: STAKE}
        )

        let selfStake = await staking.poolSelfStake(agent.address)
        expect(selfStake).to.be.equal(STAKE)

        await wToken.connect(agent).deposit({value: STAKE})
        const balance = await wToken.balanceOf(agent.address)
        expect(balance).to.be.equal(STAKE)

        await wToken.connect(agent).approve(await staking.getAddress(), STAKE)
        await staking.connect(agent).deposit(
            agent.address,
            STAKE
        )

        selfStake = await staking.poolSelfStake(agent.address)
        expect(selfStake).to.be.equal(STAKE * 2n)
    })

    it("Should be compatible with v1", async function () {
        const treasury = await rw.treasury()
        const reserve = await rw.ACPReserve()
        const minStake = await rw.minStake()

        expect(treasury).to.be.equal(owner.address)
        expect(reserve).to.be.equal(owner.address)
        expect(minStake).to.be.equal(MIN_STAKE)

        const vss = await rw.vaultSelfStake(chainID, agent.address)
        const vb = await rw.vaultBalance(chainID, agent.address)
        const vbb = await rw.vaultBalanceBatch(chainID, [agent.address])
        expect(vss).to.be.equal(STAKE * 2n)
        expect(vb).to.be.equal(STAKE * 2n)
        expect(vbb[0]).to.be.equal(STAKE * 2n)
    })

    it("Info should be updated after deposit", async function () {
        const vss = await rw.vaultSelfStake(chainID, agent.address)
        expect(vss).to.be.equal(STAKE * 2n)

        await staking.connect(dtor1).deposit(
            agent.address,
            0,
            {value:STAKE}
        )

        const vd = await staking.getPoolTotalDelegation(agent.address)
        expect(vd).to.be.equal(STAKE)
    })

    it("Should now withdraw on cooldown", async function () {
        await expect(staking.connect(dtor1).withdraw(
            agent.address,
            STAKE,
            true
        )).to.be.revertedWithCustomError(staking, "Staking__Cooldown")
    })

    it("Info should be updated after withdrawal", async function () {
        // wait for 60 seconds with emv call 
        await ethers.provider.send("evm_increaseTime", [60]);
        await ethers.provider.send("evm_mine");

        await staking.connect(dtor1).withdraw(
            agent.address,
            STAKE,
            true
        )
    })

    it("Should calculate right shares after one deposit", async function () {
        await staking.connect(dtor1).deposit(
            agent.address,
            0,
            {value:STAKE}
        )

        const positionShare = await staking.getUserDelegationSharePercent(
            dtor1.address, 
            agent.address
        )

        expect(positionShare).to.be.equal(FULL_SHARE)
    })

    it("Should calculate right shares after two deposits", async function () {
        await staking.connect(dtor2).deposit(
            agent.address,
            0,
            {value:STAKE * 3n}
        )

        let positionShare = await staking.getUserDelegationSharePercent(
            dtor1.address, 
            agent.address
        )
        expect(positionShare).to.be.equal(FULL_SHARE / 4n) 

        positionShare = await staking.getUserDelegationSharePercent(
            dtor2.address, 
            agent.address
        )
        expect(positionShare).to.be.equal(FULL_SHARE * 3n / 4n) 
    })

    it("Should distribute rewards correctly", async function () {
        let rps = await rw.getVaultRPS(chainID, agent.address)
        log("RPS before reward:", rps)
        expect(rps).to.be.equal(0n)

        await rw.setReward(
            chainID,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        const dtorRewards = DEFAULT_REWARD * DEFAULT_SHARE / FULL_SHARE

        let sharePercent = await staking.getUserDelegationSharePercent(
            dtor1.address, 
            agent.address
        )

        let pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )

        log("Delegator 1 pending rewards, after first reward:", pendingRewards)
        expect(pendingRewards).to.equal(dtorRewards * sharePercent / FULL_SHARE)

        sharePercent = await staking.getUserDelegationSharePercent(
            dtor2.address, 
            agent.address
        )

        pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor2.address
        )

        log("Delegator 2 pending rewards, after first reward:", pendingRewards)
        expect(pendingRewards).to.equal(dtorRewards * sharePercent / FULL_SHARE)

        let acc = await rw.getAccumulatedRewards(
            dtor1.address,
            chainID,
            agent.address,
        )
        log("\n")
        log("Delegator 1 acc rewards, after first reward:", acc)
        expect(acc).to.equal(0n)

        acc = await rw.getAccumulatedRewards(
            dtor2.address,
            chainID,
            agent.address,
        )
        log("Delegator 2 acc rewards, after first reward:", acc)
        expect(acc).to.equal(0n)

        const agentReward = await rw.vaultAgentRewards(
            chainID,
            agent.address
        )
        expect(agentReward).to.equal(DEFAULT_REWARD - dtorRewards)
    })

    it("RPS should be updated", async function () {
        let rps = await rw.getVaultRPS(chainID, agent.address)
        log("RPS after reward:", rps)
        expect(rps).to.not.be.equal(0n)
    })


    it("Should show batch of vaults rewards", async function () {
        await rw.setReward(
            2n, // new chain 
            agent.address,
            DEFAULT_REWARD,
            false
        )

        const rewards = await rw.agentVaultBatchRewards(
            agent.address,
            [chainID, 2n],
        )

        log("Agent multi vault rewards:", rewards)
        expect(rewards).to.deep.equal([DEFAULT_REWARD / 2n, DEFAULT_REWARD / 2n])
    })

    it("Compensation only goes to agent reward", async function () {
        let agentReward = await rw.vaultAgentRewards(
            chainID,
            agent.address
        )

        await rw.setReward(
            chainID,
            agent.address,
            DEFAULT_REWARD,
            true
        )

        const newAgentReward = await rw.vaultAgentRewards(
            chainID,
            agent.address
        )

        // distributes full as it is compensation
        expect(newAgentReward).to.equal(agentReward + DEFAULT_REWARD)
    })


    it("Deposit should NOT affect existing rewards", async function () {
        const pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor2.address
        )
        log("Delegator 2 pending rewards, after first reward:", pendingRewards)

        const sharePercent = await staking.getUserDelegationSharePercent(
            dtor2.address, 
            agent.address
        )

        const rewardDebt = await rw.getRewardDebt(
            dtor2.address,
            chainID,
            agent.address
        )

        const acc = await rw.getAccumulatedRewards(
            dtor2.address,
            chainID,
            agent.address
        )

        rewardsDtor1CheckPoint = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )

        rewardsDtor2CheckPoint = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor2.address
        )

        // DEPOSIT
        await staking.connect(dtor2).deposit(
            agent.address,
            0,
            {value:STAKE}
        )


        const rps = await rw.getVaultRPS(chainID, agent.address)
        expect(rps).to.not.be.equal(0n)
        // hardcode a bit 
        // be sure does not change after deposit with 
        // no rewards to the vault
        expect(rps).to.equal(125000000000000n)

        const newAcc = await rw.getAccumulatedRewards(
            dtor2.address,
            chainID,
            agent.address
        )

        const newSharePercent = await staking.getUserDelegationSharePercent(
            dtor2.address, 
            agent.address
        )

        const newRewardDebt = await rw.getRewardDebt(
            dtor2.address,
            chainID,
            agent.address
        )

        log("\n")
        log("Delegator 2 accumulated before new deposit:", acc)
        log("Delegator 2 accumulated after new deposit:", newAcc)

        log("\n")
        log("Delegator 2 share percent before new deposit:", sharePercent)
        log("Delegator 2 share percent after new deposit:", newSharePercent)
        expect(newSharePercent).to.not.equal(sharePercent)

        log("\n")
        log("Delegator 2 reward debt before new deposit:", rewardDebt)
        log("Delegator 2 reward debt after new deposit:", newRewardDebt)
        expect(newRewardDebt).to.not.equal(rewardDebt)

        const newPendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor2.address
        )

        log("\n")
        log("Delegator 2 pending rewards, before new deposit:", pendingRewards)
        log("Delegator 2 pending rewards, after new deposit:", newPendingRewards)
        expect(newPendingRewards).to.equal(pendingRewards)
    })

    it("Deposit should NOT affect existing rewards of other delegator", async function () {
        const pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )
        expect(pendingRewards).to.equal(rewardsDtor1CheckPoint)
    })

    it("Should withdraw and NOT affect existing rewards", async function () {
        // wait 60 seconds with evm call 
        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");

        const pendingRewardsBefore = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor2.address
        )
        log("Pending before withdraw:", pendingRewardsBefore)

        const balanceBefore = await ethers.provider.getBalance(dtor2.address)
        await staking.connect(dtor2).withdraw(
            agent.address,
            STAKE,
            true
        )
        const txFee = ethers.parseEther("0.01")

        const balanceAfter = await ethers.provider.getBalance(dtor2.address)
        log("Balance before withdraw:", balanceBefore)
        log("Balance before withdraw + stake:", balanceBefore + STAKE)
        log("Balance after withdraw:", balanceAfter)
        expect(balanceAfter).to.be.gt(balanceBefore - txFee + STAKE)

        const pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor2.address
        )
        log("Pending after withdraw:", pendingRewards)
        expect(pendingRewards).to.equal(rewardsDtor2CheckPoint)
        expect(pendingRewards).to.not.equal(0n)
    })


    it("Withdraw should NOT affect existing rewards of other delegator", async function () {
        const pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )

        expect(pendingRewards).to.equal(rewardsDtor1CheckPoint)
    })

    it("Should harvest right rewards", async function () {
        const balanceBefore = await rtoken.balanceOf(dtor2.address)
        await rw.connect(dtor2).harvest(
            agent.address
        )
        const balanceAfter = await rtoken.balanceOf(dtor2.address)
        expect(balanceAfter).to.equal(balanceBefore + rewardsDtor2CheckPoint)
    })

    it("Other delegators rewards are NOT affected by harvest", async function () {
        const pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )

        expect(pendingRewards).to.equal(rewardsDtor1CheckPoint)
    })

    it("Rewards are correct after new rewards and after harvest", async function () {
        let pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor2.address
        )
        // dtor2 harvested his rewards
        expect(pendingRewards).to.equal(0n)

        pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )
        // dtor1 does not harvested his rewards
        expect(pendingRewards).to.equal(rewardsDtor1CheckPoint)

        // NEW REWARD
        await rw.setReward(
            chainID,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        const share1 = await staking.getUserDelegationSharePercent(
            dtor1.address, 
            agent.address
        )

        const share2 = await staking.getUserDelegationSharePercent(
            dtor2.address, 
            agent.address
        )

        const dtorReward = DEFAULT_REWARD / 2n

        pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor2.address
        )
        // dtor2 has received new reward
        expect(pendingRewards).to.equal(dtorReward * share2 / FULL_SHARE)
        rewardsDtor2CheckPoint= pendingRewards

        pendingRewards = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )
        // dtor1 has received new reward with old reward unaffected
        expect(pendingRewards).to.equal(dtorReward * share1 / FULL_SHARE + rewardsDtor1CheckPoint)
        rewardsDtor1CheckPoint = pendingRewards
    })

    it("Rewards are correct after new rewards and with different stakes", async function () {
        await staking.connect(dtor3).deposit(
            agent.address,
            0,
            {value: STAKE * 5n}
        )

        // NEW REWARD
        await rw.setReward(
            chainID,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        const dtorReward = DEFAULT_REWARD / 2n

        const share1 = await staking.getUserDelegationSharePercent(
            dtor1.address, 
            agent.address
        )

        const share2 = await staking.getUserDelegationSharePercent(
            dtor2.address, 
            agent.address
        )

        const share3 = await staking.getUserDelegationSharePercent(
            dtor3.address, 
            agent.address
        )

        const reward1 = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )
        const percentPrecision = ethers.parseUnits("1", 14)

        expect(reward1).to.be.gt(rewardsDtor1CheckPoint + dtorReward * share1 / FULL_SHARE - percentPrecision)

        const reward2 = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor2.address
        )
        expect(reward2).to.be.gt(rewardsDtor2CheckPoint + dtorReward * share2 / FULL_SHARE - percentPrecision)

        const reward3 = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor3.address
        )
        expect(reward3).to.be.gt(dtorReward * share2 / FULL_SHARE - percentPrecision)

        log("New rewards of 3 delegators:")
        log(reward1)
        log(reward2)
        log(reward3)
    })

    it("Should harvest right rewards by agent", async function () {
        const agentRewards = await rw.vaultAgentRewards(
            chainID,
            agent.address
        )
        const balanceBefore = await rtoken.balanceOf(agent.address)
        const token = await rw.tokens(chainID)
        log("reward token in rewards:", token)
        expect(token).to.not.equal(ethers.ZeroAddress)

        await rw.connect(agent).harvest(
            agent.address
        )
        const balanceAfter = await rtoken.balanceOf(agent.address)
        expect(balanceAfter).to.be.equal(balanceBefore + agentRewards)
    })

    it("Should slash agent", async function () {
        ////// slash checkpoint
        const rewards1 = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )
        rewardsDtor1CheckPoint = rewards1
        const agentRewards = await rw.vaultAgentRewards(
            chainID,
            agent.address
        )
        agentRewardsCheckPoint = agentRewards
        ///// 

        const vaultSelfStakeBefore = await rw.vaultSelfStake(
            chainID,
            agent.address
        )

        // we are slashing through 
        // reward contract for compatibility
        await rw.slash(
            chainID,
            agent.address,
            10n
        )

        const vaultSelfStakeAfter = await rw.vaultSelfStake(
            chainID,
            agent.address
        )
        expect(vaultSelfStakeAfter).to.equal(vaultSelfStakeBefore - 10n)
    })

    it("Slashing does not affect rewards", async function () {
        const agentRewards = await rw.vaultAgentRewards(
            chainID,
            agent.address
        )
        expect(agentRewards).to.equal(agentRewardsCheckPoint)

        const rewards1 = await rw.delegatorPendingRewards(
            chainID,
            agent.address,
            dtor1.address
        )
        expect(rewards1).to.equal(rewardsDtor1CheckPoint)
    })

    it("Should unstake all", async function () {
        const agent1Stake = await staking.getUserDelegation(dtor2.address, agent.address)

        // stake to agent 2
        await staking.connect(dtor2).deposit(
            agent2.address,
            0,
            {value: STAKE}
        )

        // wait 60 secs with evm call 
        await ethers.provider.send("evm_increaseTime", [3600]);
        await ethers.provider.send("evm_mine");

        const balanceBefore = await ethers.provider.getBalance(dtor2.address)
        const txFee = ethers.parseEther("0.1")

        await staking.connect(dtor2).withdrawAll(true)

        log("Dtor2 balance before unstake all:", ethers.formatEther(balanceBefore))
        log("Dtor2 delegations before unstake all:")
        log("Agent 1 stake:", agent1Stake)
        log("Agent 2 stake:", STAKE)
        const balanceAfter = await ethers.provider.getBalance(dtor2.address)

        log("Dtor2 balance after unstake all:", ethers.formatEther(balanceAfter))

        expect(balanceAfter).to.be.gt(balanceBefore - txFee + agent1Stake + STAKE)
    })

    it("Should NOT unstake all by agent", async function () {
        const selfStake = await rw.vaultSelfStake(
            chainID,
            agent.address
        )
        const balanceBefore = await ethers.provider.getBalance(agent.address)


        await staking.connect(agent).withdrawAll(true)

        const selfStakeAfter = await rw.vaultSelfStake(
            chainID,
            agent.address
        )
        const balanceAfter = await ethers.provider.getBalance(agent.address)
        const txFee = ethers.parseEther("0.1")

        expect(balanceAfter).to.be.gt(balanceBefore - txFee)
        expect(balanceAfter).to.be.lt(balanceBefore + STAKE)
        expect(selfStake).to.equal(selfStakeAfter)
    })

    it("AgentSet of user is correct", async function () {
        await staking.connect(dtor2).deposit(
            agent2.address,
            0,
            {value: STAKE}
        )

        const set = await staking.getAgentsFromSet(dtor2.address)
        log("AgentSet of dtor2:", set)
        expect(set[0]).to.be.equal(agent2.address)
    })

    it("NetworkSet of agent is correct", async function () {
        await rw.setReward(
            3n,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        const networkSet = await rw.getAgentNetworkSet(agent.address)
        log("NetworkSet of agent:", networkSet)
        expect(networkSet[0]).to.be.equal(1n)
        expect(networkSet[1]).to.be.equal(2n)
        expect(networkSet[2]).to.be.equal(3n)
    })

    it("Should harvest all networks", async function () {
        await staking.connect(dtor2).deposit(
            agent.address,
            0,
            {value: STAKE}
        )

        await rw.setReward(
            1n,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        await rw.setReward(
            2n,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        await rw.setReward(
            3n,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        const pending1 = await rw.delegatorPendingRewards(
            1n,
            agent.address,
            dtor2.address
        )

        const pending2 = await rw.delegatorPendingRewards(
            2n,
            agent.address,
            dtor2.address
        )

        const pending3 = await rw.delegatorPendingRewards(
            3n,
            agent.address,
            dtor2.address
        )

        log("Dtor2 pending rewards default agent chain id 1:", pending1)
        log("Dtor2 pending rewards default agent chain id 2:", pending2)
        log("Dtor2 pending rewards default agent chain id 3:", pending3)

        const totalRew = pending1 + pending2 + pending3;
        const balanceBefore1 = await rtoken.balanceOf(dtor2.address)
        const balanceBefore2 = await rtoken2.balanceOf(dtor2.address)
        const balanceBefore3 = await rtoken3.balanceOf(dtor2.address)

        await rw.connect(dtor2).harvest(agent.address)

        // pending are now zero 
        const pending1After = await rw.delegatorPendingRewards(
            1n,
            agent.address,
            dtor2.address
        )

        const pending2After = await rw.delegatorPendingRewards(
            2n,
            agent.address,
            dtor2.address
        )

        const pending3After = await rw.delegatorPendingRewards(
            3n,
            agent.address,
            dtor2.address
        )

        expect(pending1After).to.equal(0n)
        expect(pending2After).to.equal(0n)
        expect(pending3After).to.equal(0n)

        
        const balanceAfter1 = await rtoken.balanceOf(dtor2.address)
        const balanceAfter2 = await rtoken2.balanceOf(dtor2.address)
        const balanceAfter3 = await rtoken3.balanceOf(dtor2.address)

        log("Total reward:", ethers.formatEther(totalRew))

        expect(balanceAfter1).to.be.equal(balanceBefore1 + pending1)
        expect(balanceAfter2).to.be.equal(balanceBefore2 + pending2)
        expect(balanceAfter3).to.be.equal(balanceBefore3 + pending3)
    })

    it("Should harvest all networks all agents", async function () {
        await staking.connect(dtor2).deposit(
            agent2.address,
            0,
            {value: STAKE}
        )
        
        await staking.connect(agent2).setRewardShare(DEFAULT_SHARE)

        await rw.setReward(
            1n,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        await rw.setReward(
            2n,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        await rw.setReward(
            1n,
            agent2.address,
            DEFAULT_REWARD,
            false
        )

        await rw.setReward(
            2n,
            agent2.address,
            DEFAULT_REWARD,
            false
        )

        const pending1 = await rw.delegatorPendingRewards(
            1n,
            agent.address,
            dtor2.address
        )

        const pending2 = await rw.delegatorPendingRewards(
            2n,
            agent.address,
            dtor2.address
        )

        const pending3 = await rw.delegatorPendingRewards(
            1n,
            agent2.address,
            dtor2.address
        )

        const pending4 = await rw.delegatorPendingRewards(
            2n,
            agent2.address,
            dtor2.address
        )

        log("Dtor2 pending rewards default agent chain id 1:", pending1)
        log("Dtor2 pending rewards default agent chain id 2:", pending2)
        log("Dtor2 pending rewards default agent2 chain id 1:", pending3)
        log("Dtor2 pending rewards default agent2 chain id 2:", pending4)
        expect(pending1).to.not.equal(0n)
        expect(pending2).to.not.equal(0n)
        expect(pending3).to.not.equal(0n)
        expect(pending4).to.not.equal(0n)

        const balance1Before = await rtoken.balanceOf(dtor2.address)
        const balance2Before = await rtoken2.balanceOf(dtor2.address)

        await rw.connect(dtor2).harvestAll()

        const balance1After = await rtoken.balanceOf(dtor2.address)
        const balance2After = await rtoken2.balanceOf(dtor2.address)

        expect(balance1After).to.be.equal(balance1Before + pending1 + pending3)
        expect(balance2After).to.be.equal(balance2Before + pending2 + pending4)
    })

    it("Should update vaults positions on deposit", async function () {
        // ensure RPS exists on agent vault 
        const rps1 = await rw.getVaultRPS(1n, agent.address)
        log("RPS 1:", rps1)
        expect(rps1).to.not.equal(0n)

        const rps2 = await rw.getVaultRPS(2n, agent.address)
        log("RPS 2:", rps2)
        expect(rps2).to.not.equal(0n)

        await rw.setReward(
            1n,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        // ensure rps is changing
        const rps1Between = await rw.getVaultRPS(1n, agent.address)
        log("RPS 1 between:", rps1Between)
        expect(rps1Between).to.not.equal(rps1)

        const rewardDebt1 = await rw.getRewardDebt(dtor2.address, 1n, agent.address)
        log("Reward Debt 1:", rewardDebt1)
        expect(rewardDebt1).to.not.equal(0n)

        const rewardDebt2 = await rw.getRewardDebt(dtor2.address, 2n, agent.address)
        log("Reward Debt 2:", rewardDebt2)
        expect(rewardDebt2).to.not.equal(0n)

        await rw.setReward(
            2n,
            agent.address,
            DEFAULT_REWARD,
            false
        )

        await rw.setReward(
            1n,
            agent2.address,
            DEFAULT_REWARD,
            false
        )

        await staking.connect(dtor2).deposit(
            agent.address,
            0,
            {value: STAKE}
        )

        const rewardDebt1After = await rw.getRewardDebt(dtor2.address, 1n, agent.address)
        log("Reward Debt 1 after:", rewardDebt1After)
        expect(rewardDebt1After).to.not.equal(rewardDebt1)

        const rewardDebt2After = await rw.getRewardDebt(dtor2.address, 2n, agent.address)
        log("Reward Debt 2 after:", rewardDebt2After)
        expect(rewardDebt2After).to.not.equal(rewardDebt2)

        const agentSet = await staking.getAgentsFromSet(dtor2.address)
        log("Agent Set:", agentSet)
        expect(agentSet.length).to.equal(2)
    })
})