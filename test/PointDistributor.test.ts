import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { DFAdapter, DFOracleMock, PointDistributor, ChainInfo } from "../typechain-types"
import { main as deployDistributor } from "../scripts/deploy/PointDistributor"
import { main as deployAdapter } from "../scripts/deploy/DFAdapter"
import { main as deployChainInfo } from "../scripts/deploy/chainInfo"
import hre, { ethers, upgrades } from "hardhat";
import { expect } from "chai";

describe("PointDistributor", function() {
    let dstr: PointDistributor;
    let adapter: DFAdapter;
    let oracle: DFOracleMock;
    let chainInfo: ChainInfo
    let owner: HardhatEthersSigner;
    let srcChainKey;
    let srcChainId = 1
    let destChainKey;
    let destChainId = 2;
    let feeAmount = 100;
    let executorPart = 10
    let transmitterPart = 2

    before(async() => {
        [owner] = await hre.ethers.getSigners()

        const coder = ethers.AbiCoder.defaultAbiCoder();
        srcChainKey = coder.encode(
            ["bytes32"],
            [ethers.randomBytes(32)]
        )
        destChainKey = coder.encode(
            ["bytes32"],
            [ethers.randomBytes(32)]
        )
        
        const dstrAddr = await deployDistributor()
        dstr = await ethers.getContractAt("PointDistributor", dstrAddr, owner)

        const adapterAddr = await deployAdapter()
        adapter = await ethers.getContractAt("DFAdapter", adapterAddr, owner)

        const oracleFactory = await ethers.getContractFactory("DFOracleMock");
        oracle = await oracleFactory.deploy()

        const chainInfoAddr = await deployChainInfo()
        chainInfo = await ethers.getContractAt("ChainInfo", chainInfoAddr, owner)

        await dstr.setDFAdapter(adapterAddr)
        await dstr.setExecutorPart(executorPart)
        await dstr.setTransmitterPart(transmitterPart)

        await adapter.setDFOracle(await oracle.getAddress())
        await adapter.setChainInfo(chainInfoAddr)
        await adapter.setDataKeyToChain(srcChainId, srcChainKey)
        await adapter.setDataKeyToChain(destChainId, destChainKey)

        await oracle.setLatestUpdate(srcChainKey, 1)
        await oracle.setLatestUpdate(destChainKey, 2)

        await chainInfo.setChainInfo(
            srcChainId,
            chainInfoAddr,
            srcChainKey,
            18,
            "name",
            "name",
            "name",
            ethers.randomBytes(32),
            ethers.randomBytes(32),
            ethers.randomBytes(32)
        )
        await chainInfo.setChainInfo(
            destChainId,
            chainInfoAddr,
            destChainKey,
            18,
            "name",
            "name",
            "name",
            ethers.randomBytes(32),
            ethers.randomBytes(32),
            ethers.randomBytes(32)
        )
    })

    it("should distribute points properly between transmitters and executors", async function () {
        const transmitters = [owner.address, owner.address, owner.address]
        const transmitterTotalPart = transmitters.length * transmitterPart

        const executors = [owner.address]
        const executorTotalPart = executors.length * executorPart

        const totalPoints = transmitterTotalPart + executorTotalPart

        const transmitterRewards = transmitters.map(() => {
            return ethers.toBigInt(Math.floor((transmitterTotalPart * feeAmount) / totalPoints))
        })

        let executorRewards = []
        for (let i = 0; i < executors.length; i++) {
            let temp = Math.floor((executorTotalPart * feeAmount) / totalPoints)
            executorRewards[i] = await adapter.convertAmount(srcChainId, destChainId, temp)
        }

        const res = await dstr.distributeRewardsCalculation(transmitters, executors, feeAmount, srcChainId, destChainId)

        expect(res[0].toString()).to.be.eq(transmitterRewards.toString())
        expect(res[1].toString()).to.be.eq(executorRewards.toString())
    })
})