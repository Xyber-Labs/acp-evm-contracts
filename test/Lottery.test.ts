import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { BytesLike } from "ethers";
import { log } from "./testLogger";
import { ExecutorLotteryTest } from "../typechain-types";
import { TEST_CHAIN_ID } from "../utils/constants";
import { network, ethers, upgrades } from "hardhat"

describe("Lottery", function () {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;
    let lottery: ExecutorLotteryTest;

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];

        const factoryName = "ExecutorLotteryTest";
        const factory: any = await ethers.getContractFactory(factoryName);
        const args = [[
            owner.address,
            owner.address
        ]]
        //@ts-ignore
        lottery = await upgrades.deployProxy(factory, args, {
            kind: "uups"
        });
        await lottery.waitForDeployment();
    });

    it("Should run lottery", async function () {
        const randomBytesHex: BytesLike = ethers.hexlify(ethers.randomBytes(32));
        log("Lottery: payload used for test:", randomBytesHex);
 
        await lottery.runLottery(
            randomBytesHex,
            TEST_CHAIN_ID,
            randomBytesHex
        )

        await network.provider.send("evm_increaseTime", [10])
        await network.provider.send("evm_mine") 

        const data = await lottery.currentExecutionData(randomBytesHex)
        log(data)
    });
});
