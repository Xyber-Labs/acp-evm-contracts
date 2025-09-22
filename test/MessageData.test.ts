import { ethers } from "hardhat";
import { MessageData } from "../typechain-types";
import { deployMessageDataFixture } from "./deploymentFixtures";
import { expect } from "chai";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { getPrefixedMsg, getTestMsg } from "./testUtils";
import { log } from "./testLogger";

describe("MessageData", function() {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;
    let md: MessageData;
    let msg: any;
    let hash: any;

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];

        md = await deployMessageDataFixture()
        await md.grantRole(await md.PRESERVER(), owner.address)
    });

    it("Should store message", async function() {
        msg = await getTestMsg()
        hash = await getPrefixedMsg(msg)
        await md.storeMessage(hash, msg)
        log(await md.getMsg(hash))
    })

    it("Should change status", async function() {
        expect(await md.getMsgStatusByHash(hash)).to.equal(2n)
        await md.changeMessageStatus(hash, 3n)
        expect(await md.getMsgStatusByHash(hash)).to.equal(3n)
    })

    it("Should increment value", async function () {
        expect(await md.getReward(hash)).to.equal(10000n)
        await md.incrementNativeAmount(hash, 10000n)
        expect(await md.getReward(hash)).to.equal(20000n)
    })
})