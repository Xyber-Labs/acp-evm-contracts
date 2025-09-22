import { ethers, upgrades } from "hardhat";
import { expect } from "chai";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ChainInfo } from "../typechain-types";
import { loadDeploymentAddress } from "../utils/fileUtils";

describe("ChainInfo", function () {
    let chainInfo: ChainInfo;
    let deployer: HardhatEthersSigner;
    let admin: HardhatEthersSigner;
    let setter: HardhatEthersSigner;
    let other: HardhatEthersSigner;
    let adminAddr: string, setterAddr: string, otherAddr: string;
    let chainId = 1;

    before(async function () {
        [deployer, admin, setter, other] = await ethers.getSigners();
        adminAddr = await admin.getAddress();
        setterAddr = await setter.getAddress();
        otherAddr = await other.getAddress();

        const ChainInfoFactory = await ethers.getContractFactory("ChainInfo");
        chainInfo = (await upgrades.deployProxy(ChainInfoFactory, [
            [adminAddr, setterAddr, setterAddr, setterAddr]
        ], {
            kind: "uups",
            initializer: "initialize" 
        }));
        await chainInfo.waitForDeployment();
    });

    it("should grant roles correctly", async function () {
        expect(await chainInfo.hasRole(await chainInfo.ADMIN(), adminAddr)).to.be.true;
        expect(await chainInfo.hasRole(await chainInfo.SETTER(), setterAddr)).to.be.true;
    });

    it("should set chain info", async function () {
        const ep = ethers.AbiCoder.defaultAbiCoder().encode(["address"], [loadDeploymentAddress("hardhat", "Endpoint")])
        await expect(chainInfo.connect(admin).setChainInfo(
            31337,
            setterAddr,
            ethers.ZeroHash,
            18,
            "Ethereum",
            "ETH",
            "https://rpc.com",
            ep,
            ethers.ZeroHash,
            ethers.ZeroHash,
        )).to.emit(chainInfo, "ChainInfoChanged");
        const chainData = await chainInfo.getChainInfo(31337);
        expect(chainData.name).to.equal("Ethereum");
        expect(chainData.defaultRpcNode).to.equal("https://rpc.com");
    });

    it("should set GasInfo", async function () {
        await expect(chainInfo.connect(admin).setGasInfo(
            chainId,
            100,
            100,
            100
        )).to.emit(chainInfo, "ChainGasInfoChanged")
    })

    it("should deny unauthorized access", async function () {
        await expect(chainInfo.connect(other).setChainInfo(
            chainId, 
            otherAddr, 
            ethers.ZeroHash, 
            18,
            "Invalid", 
            "INV", 
            "https://rpc.com", 
            ethers.ZeroHash,
            ethers.ZeroHash,
            ethers.ZeroHash,
        )).to.be.revertedWithCustomError(chainInfo, "AccessControlUnauthorizedAccount");

        await expect(chainInfo.connect(other).setGasInfo(
            chainId,
            100,
            100,
            100
        )).to.be.revertedWithCustomError(chainInfo, "AccessControlUnauthorizedAccount");

    });

    it("should set chain params", async function () {
        await expect(chainInfo.connect(setter).setChainParams(chainId, 15, 30))
            .to.emit(chainInfo, "ChainParamsChanged");
        const chainData = await chainInfo.getChainInfo(chainId);
        expect(chainData.blockFinalizationTime).to.equal(15);
        expect(chainData.defaultExecutionTime).to.equal(30);
    });

    it("should change consensus rate", async function () {
        const rate = 7500
        await expect(chainInfo.connect(setter).changeConsensusRate(chainId, rate))
            .to.emit(chainInfo, "ConsensusRateChanged");
        expect(await chainInfo.getConsensusRate(chainId)).to.equal(rate);
    });

    it("should change super consensus rate", async function () {
        const rate = 8500
        await expect(chainInfo.connect(setter).changeSuperConsensusRate(chainId, rate))
            .to.emit(chainInfo, "SuperConsensusRateChanged");
        expect(await chainInfo.getSuperConsensusRate(chainId)).to.equal(rate);
    });

    it("should retrieve endpoint correctly", async function () {
        // const endpoint = await chainInfo.getEndpoint(chainId);
        // console.log(endpoint)
        // expect(ethers.AbiCoder.defaultAbiCoder().decode(["address"], endpoint)[0]).to.equal('0x0000000000000000000000000000000000000000');
    });

    it("should retrieve configurator correctly", async function () {
        const configurator = await chainInfo.getConfigurator(chainId);
        expect(configurator).to.equal("0x");
    });

    it("should retrieve decimals correctly", async function () {
        await chainInfo.connect(admin).setChainInfo(
            2,
            setterAddr,
            ethers.ZeroHash,
            16,
            "Solana",
            "SOL",
            "https://rpc.com",
            ethers.ZeroHash,
            ethers.ZeroHash,
            ethers.ZeroHash
        );

        const [dec1, dec2] = await chainInfo.getDecimalsByChains(chainId, 2);
        expect(dec1).to.equal(0);
        expect(dec2).to.equal(16);
    });

    it("should set finalizations", async function() {
        await chainInfo.connect(admin).setFinalizations(
            1, 
            [0, 1, 2],
            [30, 60, 0]
        )

        const finalizations = await chainInfo.getFinalizations(
            1,
            [0, 1, 2]
        )

        expect(finalizations[0]).to.equal(30)
        expect(finalizations[1]).to.equal(60)
        expect(finalizations[2]).to.equal(0)
    })
});
