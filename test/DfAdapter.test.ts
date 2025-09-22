import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { DFAdapter, DFOracleMock, ChainInfo } from "../typechain-types"
import hre, { ethers, upgrades } from "hardhat";
import { expect } from "chai";

describe("DFAdapter", function() {
    let adapter: DFAdapter;
    let oracle: DFOracleMock;
    let chainInfo: ChainInfo;
    let owner: HardhatEthersSigner;
    const srcChainId = 1 
    const destChainId = 2 

    const srcPrice = 1000n;
    const destPrice = 2000n;

    before(async() => {
        [owner] = await hre.ethers.getSigners()
        
        const oracleFactory = await ethers.getContractFactory("DFOracleMock")
        oracle = await oracleFactory.deploy()

        const ciFactoryName = "ChainInfo";
        const ciFactory: any = await ethers.getContractFactory(ciFactoryName);
        let args = [[
            owner.address, 
            owner.address, 
            owner.address,
            owner.address,
            owner.address,
            owner.address
        ]];
        // @ts-ignore
        chainInfo = await upgrades.deployProxy(ciFactory, args, {
            kind: "uups",
        });
        await chainInfo.waitForDeployment();

        const adapterFactory = await ethers.getContractFactory("DFAdapter")
        args = [[owner.address]] 
        // @ts-ignore
        adapter = await upgrades.deployProxy(adapterFactory, args, {
            kind: "uups"
        })
        await adapter.waitForDeployment()
        await adapter.setDFOracle(await oracle.getAddress())
        await adapter.setChainInfo(await chainInfo.getAddress())

        // need for further tests
        const coder = ethers.AbiCoder.defaultAbiCoder();
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
            2,           
            "0x0000000000000000000000000000000000000001", 
            "0x4d4e542f55534400000000000000000000000000000000000000000000000000",
            9,
            "Solana",     
            "SOL",  
            "https://sepolia.gateway.tenderly.co",      
            "0x00000000000000000000000094c78fbf9e269c1ef8ae41c66f961c5f283ef623",   
            "0x00000000000000000000000094c78fbf9e269c1ef8ae41c66f961c5f283ef623",   
            random_oracle,
        );
    })

    it("should set data keys", async function () {
        await adapter.setDataKeyToChain(1, "0x4554482f55534400000000000000000000000000000000000000000000000000");
        await adapter.setDataKeyToChain(2, "0x4d4e542f55534400000000000000000000000000000000000000000000000000");
        await oracle.setLatestUpdate("0x4554482f55534400000000000000000000000000000000000000000000000000", srcPrice);
        await oracle.setLatestUpdate("0x4d4e542f55534400000000000000000000000000000000000000000000000000", destPrice);
    })

    it("should get rate by chain id", async function () {
        // in DFOracleMock latest price = 100
        expect(await adapter.getRate(srcChainId)).to.be.eq(srcPrice)
        expect(await adapter.getRate(destChainId)).to.be.eq(destPrice)
    })

    it("should convert src native to dest native", async function () {
        const amount = 1000000000000000000n;
        const srcDecimals = 18n;
        const destDecimals = 9n;
        // expected result src -> dest
        let expRes = (amount * srcPrice * (10n ** destDecimals)) / (destPrice * (10n ** srcDecimals))
        expect(await adapter.convertAmount(srcChainId, destChainId, amount)).to.be.eq(expRes)

        // expected result dest -> res
        expRes = (amount * destPrice * (10n ** srcDecimals)) / (srcPrice * (10n ** destDecimals))
        expect(await adapter.convertAmount(destChainId, srcChainId, amount)).to.be.eq(expRes)
    })
})