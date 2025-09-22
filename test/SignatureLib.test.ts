import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { TestSelectorLib } from "../typechain-types";
import { encodeDefaultSelector, encodeExecutionCode, getTestMsg, signConsensus } from "./testUtils";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { log } from "./testLogger"
import hre, { ethers } from "hardhat";
import { selector, exCode } from "./testUtils";
import { Master } from "../typechain-types";
import { SigsEncoderMock } from "../typechain-types";

describe("SelectorLib", function () {
    let signers: HardhatEthersSigner[];
    let msg: any;
    let sigs: any;
    let pureSigs: any[];
    let packedSigs: any;
    let owner: HardhatEthersSigner;  
    let lib: SigsEncoderMock;  

    async function deploySigsEncoder() {
        const TestFactory: any =
            await hre.ethers.getContractFactory("SigsEncoderMock");
        
        const signatureLibTest = await TestFactory.deploy();
        await signatureLibTest.waitForDeployment();

        return signatureLibTest as unknown as SigsEncoderMock;
    }

    before(async () => {
        signers = (await ethers.getSigners()).slice(1,4);
        owner = signers[0];
        msg = await getTestMsg()
        sigs = await signConsensus(signers, msg)

        pureSigs = sigs.map((sig: any) => {
            return ethers.Signature.from(sig)
        })

        console.log(pureSigs)

        lib = await deploySigsEncoder()
    });

    it("Should pack sigs", async function () {
        packedSigs = await lib.encodePureSigs(pureSigs)
        console.log(packedSigs)
    });

    it("Should unpack sigs", async function () {
        const res = await lib.decodePackedSigs(packedSigs)
        console.log(res)
    })
})