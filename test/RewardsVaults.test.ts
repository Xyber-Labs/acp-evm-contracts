import { ethers, upgrades } from "hardhat";
import { ERC20Mock, ERC20Mock__factory, RewardVaults, WToken, WToken__factory } from "../typechain-types";
import { log } from "./testLogger";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { emitWarning } from "process";
import { time } from "@nomicfoundation/hardhat-network-helpers";

const chainID = 1;

async function deployRewardVaults(owner: any) {
    const factory: any = await ethers.getContractFactory("RewardVaults");
    const instance = await upgrades.deployProxy(factory, 
        [[
            owner.address,
            ethers.ZeroAddress,
            ethers.ZeroAddress,
            ethers.ZeroAddress
        ]], 
        {
            kind: "uups"
        }
    );
    await instance.waitForDeployment();

    return instance as unknown as RewardVaults;
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

describe("RewardVaults", function() {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;
 
    let rw: RewardVaults;
    let rtoken: ERC20Mock; // reward ATS token for chain
    let wToken: any;

    let treasury: HardhatEthersSigner;
    let agent: HardhatEthersSigner;
    let dtor1: HardhatEthersSigner;
    let dtor2: HardhatEthersSigner;
    let dtor3: HardhatEthersSigner;

    // temporary options
    let vaultDShare = 90n * 100n;
    let defRewAmount = 1000n
    let AGENT_DEPOSIT = 1000n
    let DTOR1_DEPOSIT = 1000n
    let DTOR2_DEPOSIT = 3000n
    let DTOR3_DEPOSIT = 1000n
    let FULL_SHARE = 10000n

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];
        agent = signers[1];
        dtor1 = signers[2];
        dtor2 = signers[3];
        dtor3 = signers[4];
        treasury = signers[5];

        log("Deploying mocks...")
        rw = await deployRewardVaults(owner)
        wToken = await deployWToken()
        rtoken = await deployTokenMock()

        // fake connected contracts as owner address
        await rw.grantRole(await rw.SLASHER(), owner.address)
        await rw.grantRole(await rw.DEPOSITOR(), owner.address)
        await rw.grantRole(await rw.REWARDER(), owner.address)

        // setup contract
        await rw.setWNative(await wToken.getAddress())
        await rw.setToken(chainID, await rtoken.getAddress())
        await rw.setTreasury(await treasury.getAddress())
        await rw.setCooldown(60n)
    });

    it("Should setup agent vault", async function() {
        // set 90% for delegators
        await rw.connect(agent).setRewardShare(chainID, vaultDShare)

        const percent = await rw.vaultDelegationSharePercent(chainID, agent.address)
        expect(percent).to.be.eq(BigInt(vaultDShare))
    })

    it("Vault info updated after deposit", async function() {
        await wToken.connect(dtor1).deposit({value: DTOR1_DEPOSIT})
        expect(await wToken.balanceOf(dtor1.address)).to.be.eq(DTOR1_DEPOSIT)

        await wToken.connect(dtor1).approve(await rw.getAddress(), DTOR1_DEPOSIT)

        // try all deposit methods
        const addr = await agent.getAddress()
        await rw.connect(dtor1).deposit(chainID, addr, 100)
        await rw.connect(dtor1).deposit(chainID, addr, 0, {value: 100})
        await rw.connect(dtor1).deposit(chainID, addr, 400, {value: 400})

        const vaultBalance = await rw.vaultBalance(chainID, addr)
        expect(vaultBalance).to.be.eq(DTOR1_DEPOSIT)
        
        const delegation = await rw.delegation(chainID, addr, dtor1.address)
        expect(delegation).to.be.eq(DTOR1_DEPOSIT)

        const dtorSharePercent = await rw.delegatorSharePercent(chainID, addr, dtor1.address)
        expect(dtorSharePercent).to.be.eq(FULL_SHARE)

        // agent deposit (self-stake)
        await wToken.connect(agent).deposit({value: AGENT_DEPOSIT})
        expect(await wToken.balanceOf(agent.address)).to.be.eq(AGENT_DEPOSIT)
        await wToken.connect(agent).approve(await rw.getAddress(), AGENT_DEPOSIT)
        await rw.connect(agent).deposit(chainID, agent.address, AGENT_DEPOSIT)

        const vaultBalance2 = await rw.vaultBalance(chainID, addr)
        expect(vaultBalance2).to.be.eq(AGENT_DEPOSIT + DTOR1_DEPOSIT)

        const netInfo = await rw.getNetInfo(agent.address)
        expect(netInfo[0][0]).to.be.eq(chainID)
        expect(netInfo[1][0]).to.be.eq(agent.address)
    })

    it("Should calculate right shares", async function() {
        await wToken.connect(dtor2).deposit({value: DTOR2_DEPOSIT})
        expect(await wToken.balanceOf(dtor2.address)).to.be.eq(DTOR2_DEPOSIT)

        await wToken.connect(dtor2).approve(await rw.getAddress(), DTOR2_DEPOSIT)
        const addr = await agent.getAddress()
        await rw.connect(dtor2).deposit(chainID, addr, DTOR2_DEPOSIT)

        const delegation = await rw.delegation(chainID, addr, dtor2.address)
        expect(delegation).to.be.eq(DTOR2_DEPOSIT)

        const vaultBalance = await rw.vaultBalance(chainID, addr)
        expect(vaultBalance).to.be.eq(AGENT_DEPOSIT + DTOR1_DEPOSIT + DTOR2_DEPOSIT)

        const dtorSharePercent = await rw.delegatorSharePercent(chainID, addr, dtor2.address)
        log(dtorSharePercent)
        expect(dtorSharePercent).to.be.eq(DTOR2_DEPOSIT * FULL_SHARE / (DTOR1_DEPOSIT + DTOR2_DEPOSIT))
        const dtor1SharePercent = await rw.delegatorSharePercent(chainID, addr, dtor1.address)
        expect(dtor1SharePercent).to.be.eq(DTOR1_DEPOSIT * FULL_SHARE / (DTOR1_DEPOSIT + DTOR2_DEPOSIT))
    })


    it("Should distibute valid rewards proportionally", async function() {
        const addr = await agent.getAddress()
        await rw.setReward(chainID, addr, defRewAmount, false)

        const totalRew = await rw.vaultTotalAccumulated(chainID, addr)
        expect(totalRew).to.be.eq(defRewAmount)

        const agentRew = await rw.vaultAgentRewards(chainID, addr)
        expect(agentRew).to.be.eq(defRewAmount * (FULL_SHARE - vaultDShare) / FULL_SHARE)

        const dtorRew = await rw.vaultDelegationAccumulated(chainID, addr)
        expect(dtorRew).to.be.eq(900n)

        const rps = await rw.vaultRPS(chainID, addr)
        expect(rps).not.to.be.eq(0n)

        const dtor1Share = await rw.delegatorSharePercent(chainID, addr, dtor1.address)
        const dtor2Share = await rw.delegatorSharePercent(chainID, addr, dtor2.address)

        const dtor1Rew = await rw.delegatorPendingRewards(chainID, addr, dtor1.address)
        expect(dtor1Rew).to.be.eq(900n * 2500n / 10000n)
        expect(dtor1Rew).to.be.eq((defRewAmount * vaultDShare / FULL_SHARE) * dtor1Share / FULL_SHARE)

        const dtor2Rew = await rw.delegatorPendingRewards(chainID, addr, dtor2.address)
        expect(dtor2Rew).to.be.eq((defRewAmount * vaultDShare / FULL_SHARE) * dtor2Share / FULL_SHARE)
    })

    it("Should calculate valid debt", async function() {
        const addr = await agent.getAddress()

        const dtor1Debt = await rw.delegatorRewardDebt(chainID, addr, dtor1.address)
        expect(dtor1Debt).to.be.eq(0n)

        const dtor2Debt = await rw.delegatorRewardDebt(chainID, addr, dtor2.address)
        expect(dtor2Debt).to.be.eq(0n)

        await wToken.connect(dtor3).deposit({value: DTOR3_DEPOSIT})
        expect(await wToken.balanceOf(dtor3.address)).to.be.eq(DTOR3_DEPOSIT)

        await wToken.connect(dtor3).approve(await rw.getAddress(), DTOR3_DEPOSIT)
        await rw.connect(dtor3).deposit(chainID, addr, DTOR3_DEPOSIT)

        const delegationRew = await rw.vaultDelegationAccumulated(chainID, addr)
        expect(delegationRew).to.be.eq(defRewAmount * vaultDShare / FULL_SHARE)

        const dtor1Share = await rw.delegatorSharePercent(chainID, addr, dtor1.address)
        const dtor2Share = await rw.delegatorSharePercent(chainID, addr, dtor2.address)
        const dtor3Share = await rw.delegatorSharePercent(chainID, addr, dtor3.address)
        log(dtor1Share, dtor2Share, dtor3Share)

        const rps = await rw.vaultRPS(chainID, addr)
        log("RPS", rps)

        const dtor3Debt = await rw.delegatorRewardDebt(chainID, addr, dtor3.address)
        log("dtor3 debt", dtor3Debt)
        expect(dtor3Debt).to.be.eq(
            (DTOR1_DEPOSIT * rps) / BigInt(10**18)
        )

        const dtor3Rew = await rw.delegatorPendingRewards(chainID, addr, dtor3.address)
        log("Rew3 after 3 deposit:", dtor3Rew)
        expect(dtor3Rew).to.be.eq(0n)

        // 1 and 2 delegator rewards do not change !!!
        const dtor1Rew = await rw.delegatorPendingRewards(chainID, addr, dtor1.address)
        log("Rew1 after 3 deposit:", dtor1Rew)
        expect(dtor1Rew).to.be.eq((vaultDShare * defRewAmount / FULL_SHARE) * DTOR1_DEPOSIT / (DTOR1_DEPOSIT + DTOR2_DEPOSIT))

        const dtor2Rew = await rw.delegatorPendingRewards(chainID, addr, dtor2.address)
        log("Rew2 after 3 deposit:", dtor2Rew)
        expect(dtor2Rew).to.be.eq((vaultDShare * defRewAmount / FULL_SHARE) * DTOR2_DEPOSIT / (DTOR1_DEPOSIT + DTOR2_DEPOSIT))

        expect(dtor1Rew + dtor2Rew + dtor3Rew).to.be.eq(vaultDShare * defRewAmount / FULL_SHARE)
    })

    it("Should calculate valid rewards with different debt", async function() {
        const addr = await agent.getAddress()
        await rw.setReward(chainID, addr, defRewAmount, false)

        const delegetorRew = await rw.vaultDelegationAccumulated(chainID, addr)
        expect(delegetorRew).to.be.eq((vaultDShare * defRewAmount / FULL_SHARE) * 2n)

        const dtor1Rew = await rw.delegatorPendingRewards(chainID, addr, dtor1.address)
        log("Dtor1 reward", dtor1Rew)

        const dtor2Rew = await rw.delegatorPendingRewards(chainID, addr, dtor2.address)
        log("Dtor2 reward", dtor2Rew)

        const dtor3Rew = await rw.delegatorPendingRewards(chainID, addr, dtor3.address)
        log("Dtor3 reward", dtor3Rew)
        expect(dtor3Rew).to.be.eq(
            await rw.vaultDelegationAccumulated(chainID, addr) - dtor1Rew - dtor2Rew
        )
        expect(dtor1Rew).to.be.gt(dtor3Rew)
    })

    it("Should harvest", async function() {
        let pending = await rw.delegatorPendingRewards(chainID, agent.address, dtor1.address)
        console.log("before:", pending);
        await rw.connect(dtor1).harvest(chainID, agent.address, dtor1.address)

        const balance = await rtoken.balanceOf(dtor1.address)
        expect(balance).to.be.gt(0n)
        expect(balance).to.be.eq(pending)
        pending = await rw.delegatorPendingRewards(chainID, agent.address, dtor1.address);
        console.log("after:", pending);
        expect(pending).to.equal(0);
    })

    it("Should agent harvest", async function() {
        const pending = await rw.vaultAgentRewards(chainID, agent.address)
        await rw.connect(agent).harvest(chainID, agent.address, agent.address)

        const balance = await rtoken.balanceOf(agent.address)
        expect(balance).to.be.gt(0n)
        expect(balance).to.be.eq(pending)
    })

    it("Should set right net info", async function() {
        await rw.connect(dtor1).deposit(2n, agent.address, 1n)
        await rw.connect(dtor1).deposit(2n, dtor2.address, 1n)
        await rw.connect(dtor1).deposit(1n, agent.address, 1n)

        const netInfo = await rw.getNetInfo(dtor1.address)
        // console.log(netInfo)

        expect(netInfo[0][0]).to.be.eq(1n)
        expect(netInfo[0][1]).to.be.eq(2n)
        expect(netInfo[1][0]).to.be.eq(agent.address)
        expect(netInfo[1][1]).to.be.eq(dtor2.address)
    })

    it("Should harvest all", async function() {
        await rw.connect(dtor1).harvestAll()
    })

    it("Should not withdraw stake on cooldown", async function() {
        await expect(rw.connect(dtor1).withdraw(
            chainID, 
            agent.address, 
            100n, 
            false
        )).to.be.revertedWithCustomError(rw, "RewardVaults__Cooldown")
    })


    it("Should withdraw delegator stake", async function() {
        // wait 60 seconds with evm node
        await ethers.provider.send("evm_increaseTime", [60 * 60])

        const delegation1 = await rw.delegation(chainID, agent.address, dtor1.address)
        const share1 = await rw.delegatorSharePercent(chainID, agent.address, dtor1.address)
        log("share 1:", share1)

        await rw.connect(dtor1).withdraw(chainID, agent.address, 100n, false)

        const delegationAfter = await rw.delegation(chainID, agent.address, dtor1.address)
        expect(delegation1 - delegationAfter).to.be.eq(100n)

        const shareAfter = await rw.delegatorSharePercent(chainID, agent.address, dtor1.address)
        log("share 1 after:", shareAfter)
        expect(share1).to.be.gt(shareAfter)
    })

    it("Should withdraw agent stake", async function() {
        const vaultBalance = await rw.vaultSelfStake(chainID, agent.address)
        const agentBalance = await wToken.balanceOf(agent.address)

        await rw.connect(agent).withdraw(chainID, agent.address, 100n, false)

        const vaultBalanceAfter = await rw.vaultSelfStake(chainID, agent.address)
        const agentBalanceAfter = await wToken.balanceOf(agent.address)

        expect(vaultBalance - vaultBalanceAfter).to.be.eq(100n)
        expect(agentBalanceAfter - agentBalance).to.be.eq(100n)
    })

    it("Should unstake all", async function () {
        await time.increase(100)

        const delegation = await rw.delegation(chainID, agent.address, dtor1.address)
        const balance = await wToken.balanceOf(dtor1.address)

        const unwrap = false
        await rw.connect(dtor1).withdrawAll(unwrap)

        const delegationAfter = await rw.delegation(chainID, agent.address, dtor1.address)
        const balanceAfter = await wToken.balanceOf(dtor1.address)
        
        expect(delegationAfter).to.be.eq(0n)
        expect(balanceAfter).to.be.eq(balance + delegation)
    })

    it("Can slash agent", async function() {
        const treasuryAddr = await rw.treasury()
        expect(treasuryAddr).to.be.eq(treasury.address)

        const vaultBalance = await rw.vaultSelfStake(chainID, agent.address)
        await rw.slash(chainID, agent.address, 100n)
        const balanceAfter = await rw.vaultSelfStake(chainID, agent.address)
        expect(vaultBalance - balanceAfter).to.be.eq(100n)

        const slash = await wToken.balanceOf(treasury.address)
        expect(slash).to.be.eq(100n)
    })
})