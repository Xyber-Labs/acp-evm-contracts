import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { ChainInfo } from "../typechain-types";
import { upgrades, ethers } from "hardhat"
import { expect } from "chai"
import { BytesLike } from "ethers";
import { getNonEVMChainId } from "../scripts/config/nonEVMChainGetter";

describe("ChainInfo config", function () {
    let chainInfo: ChainInfo;
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;
    let otherAccount: HardhatEthersSigner;
    let oracle: BytesLike;
    let gasLimit = 30000000;

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];
        otherAccount = signers[1];

        const coder = ethers.AbiCoder.defaultAbiCoder();
        oracle = coder.encode(
            ["address"],
            [ethers.ZeroAddress]
        )

        const factoryName = "ChainInfo";
        const factory: any = await ethers.getContractFactory(factoryName);
        const args = [[
            owner.address, 
            owner.address, 
            owner.address, 
            owner.address, 
            owner.address, 
            owner.address
        ]];
        // @ts-ignore
        chainInfo = await upgrades.deployProxy(factory, args, {
            kind: "uups",
        });
        await chainInfo.waitForDeployment();
    });

    describe("ConfigTests", function () {
        it("Should set the right params", async function () {
            await expect(
                await chainInfo.connect(owner).setChainInfo(
                    11155111,           
                    "0x876F27492cD25F79CC2F18f3Aed757508AAcE99F", 
                    "0x6173667364667661644344460000000000000000000000000000000000000000",
                    18,
                    "Ethereum Sepolia",     
                    "ETH",  
                    "https://sepolia.gateway.tenderly.co",
                    "0x6173667364667661644344460000000000000000000000000000000000000000",
                    "0x6173667364667661644344460000000000000000000000000000000000000000",
                    oracle
                )
            )
                .to.emit(chainInfo, "ChainInfoChanged")
                .withArgs(
                    11155111,           
                    "0x876F27492cD25F79CC2F18f3Aed757508AAcE99F", 
                    "0x6173667364667661644344460000000000000000000000000000000000000000",
                    "Ethereum Sepolia",     
                    "ETH",  
                    "https://sepolia.gateway.tenderly.co",
                    18,
                    "0x6173667364667661644344460000000000000000000000000000000000000000",
                    "0x6173667364667661644344460000000000000000000000000000000000000000",
                    oracle,
                );

            await expect(
                await chainInfo.connect(owner).setGasInfo(
                    11155111,
                    100,
                    200,
                    300
                )
            ).to.emit(chainInfo, "ChainGasInfoChanged")
            .withArgs(
                11155111,
                100,
                200,
                300
            )
        });


        it("Should fail in case of attemp to set params not by owner", async function () {
            await expect(
                chainInfo.connect(otherAccount).setChainInfo(
                    11155111,           
                    "0x876F27492cD25F79CC2F18f3Aed757508AAcE99F", 
                    "0x6173667364667661644344460000000000000000000000000000000000000000",
                    18,
                    "Ethereum Sepolia",     
                    "ETH",  
                    "https://sepolia.gateway.tenderly.co",
                    "0x6173667364667661644344460000000000000000000000000000000000000000",
                    "0x6173667364667661644344460000000000000000000000000000000000000000",
                    oracle
                )
            ).to.be.reverted;


            await expect(
                chainInfo.connect(otherAccount).setGasInfo(
                    11155111,
                    100,
                    200,
                    300
                )
            ).to.be.reverted
        });
    });
});
