import { ethers, upgrades } from "hardhat";
import { expect } from "chai";
import { GasEstimator, Endpoint, DFOracleMock } from "../typechain-types"
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { deployEndPointFixture } from "./deploymentFixtures";
import { getSrcChainData } from "../tasks/proposalParser";

async function deployEstimator(endpoint: string) {
    const [owner] = await ethers.getSigners()

    const estFactory: any = await ethers.getContractFactory("GasEstimator");
    const args = [[
        owner.address,
        endpoint
    ]]
    //@ts-ignore
    const estimator = await upgrades.deployProxy(estFactory, args, {
        kind: "uups"
    });
    await estimator.waitForDeployment();

    return estimator as unknown as GasEstimator
}

describe("GasEstimator", function() {
    const coder = ethers.AbiCoder.defaultAbiCoder()

    const srcChainId = 31337
    const srcDataKey = ethers.randomBytes(32)
    const srcGasDataKey = ethers.randomBytes(32)
    const destChainId = 1
    const destDataKey = ethers.randomBytes(32)
    const destGasDataKey = ethers.randomBytes(32)
    
    let DFMul = 1n
    let coms = 5n
    let gasMul = 15n

    let endpoint: Endpoint
    let oracle: DFOracleMock
    let estimator: GasEstimator
    let owner: HardhatEthersSigner

    const srcChainData: GasEstimator.ChainDataStruct = {
        totalFee: 1000,
        decimals: 18,
        defaultGas: 100,
        gasDataKey: srcGasDataKey,
        nativeDataKey: srcDataKey
    }
    const destChainData: GasEstimator.ChainDataStruct = {
        totalFee: 2000,
        decimals: 18,
        defaultGas: 200n,
        gasDataKey: destGasDataKey,
        nativeDataKey: destDataKey
    }

    before(async function () {
        [owner] = await ethers.getSigners()

        endpoint = await deployEndPointFixture()
        await endpoint.setTotalActiveSigners(10)
        
        const oracleFactory = await ethers.getContractFactory("DFOracleMock")
        oracle = await oracleFactory.deploy()
        await oracle.setLatestUpdate(srcDataKey, 1)
        await oracle.setLatestUpdate(srcGasDataKey, 2)
        await oracle.setLatestUpdate(destDataKey, 3)
        await oracle.setLatestUpdate(destGasDataKey, 4)
        
        estimator = await deployEstimator(await endpoint.getAddress())
        
        await estimator.setChainData(srcChainId, srcChainData)
        await estimator.setChainData(destChainId, destChainData)
        await estimator.setDeviations(DFMul, coms, gasMul)
        await estimator.setDFOracle(await oracle.getAddress())
        
        await endpoint.setGasEstimator(await estimator.getAddress())
    })
    
    it("should return estimated gas", async function () {
        const estGasCost = await estimator.estimateExecutionWithGas(
            destChainId,
            100000
        )

        // count estGas manually and compare
        const totalFee = srcChainData.totalFee
        const sigs = await endpoint.totalActiveSigners()
        const [srcNativePrice, ] = await oracle.getFeedPrice(srcDataKey)
        const [destNativePrice, ] = await oracle.getFeedPrice(destDataKey)
        
        const consensusGas = sigs * 4000n * 15n / 10n
        const gas = Number(destChainData.defaultGas) + Number(consensusGas) + 100000
        const [destGasPrice,] = await oracle.getFeedPrice(destGasDataKey)
        const destGasFee = destGasPrice * BigInt(gas)
        const baseRate = BigInt(destGasFee) * BigInt(destNativePrice) / srcNativePrice
        const finalNonSafe = baseRate * 10n**0n
        const finalRaw = finalNonSafe + BigInt(totalFee)

        if (finalRaw < 100) {
            const manGasCost = finalRaw + BigInt(DFMul) + BigInt(coms) + BigInt(gasMul)
            expect(estGasCost).to.be.eq(manGasCost)
        } else {
            const curDFMul = BigInt(Math.floor(Number(finalRaw * DFMul/ 100n)))
            const curComs = BigInt(Math.floor(Number(finalRaw * coms / 100n)))
            const curGasMul = BigInt(Math.floor(Number(finalRaw * gasMul / 100n)))
            
            const manGasCost = finalRaw + curDFMul + curComs + curGasMul
            expect(estGasCost).to.be.eq(manGasCost)
        }
    })
    
    it("should revert if src ChainData was not set after deployment", async function () {       
        const fakeEstimator = await deployEstimator(await endpoint.getAddress())

        await expect(fakeEstimator.estimateExecutionWithGas(destChainId, 100000))
            .to.be.revertedWithCustomError(estimator, "GasEstimator__ChainInactive")
    })

    it("should revert if endpoint has 0 active signers", async function () {
        const fakeEndpoint = await deployEndPointFixture()
        const fakeEstimator = await deployEstimator(await fakeEndpoint.getAddress())
        
        const srcChainData: GasEstimator.ChainDataStruct = {
            totalFee: 1000,
            decimals: 18,
            defaultGas: 100,
            gasDataKey: srcDataKey,
            nativeDataKey: srcGasDataKey
        }
        await fakeEstimator.setChainData(srcChainId, srcChainData)

        await expect(fakeEstimator.estimateExecutionWithGas(destChainId, 100000))
            .to.be.revertedWithCustomError(estimator, "GasEstimator__ZeroActiveAgents")
    })
    
    it("should revert if oracle returns 0 as a native price", async function () {
        await oracle.setLatestUpdate(destDataKey, 0)

        await expect(estimator.estimateExecutionWithGas(destChainId, 100000))
            .to.be.revertedWithCustomError(estimator, "GasEstimator__ZeroRates")
    })

    it("should revert if gasLimit was not set", async function () {
        await expect(
            estimator.estimateExecutionWithGas(
                destChainId,
                0
            )
        ).to.be.revertedWithCustomError(estimator, "GasEstimator__ZeroGasLimit")
    })
 
});