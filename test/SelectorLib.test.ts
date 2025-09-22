import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { TestSelectorLib } from "../typechain-types";
import { encodeDefaultSelector, encodeExecutionCode, signConsensus } from "./testUtils";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { log } from "./testLogger"
import hre, { ethers } from "hardhat";
import { selector, exCode } from "./testUtils";

describe("SelectorLib", function () {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;

    async function deploySelectorLibTest() {
        const TestFactory: any =
            await hre.ethers.getContractFactory("TestSelectorLib");
        
        const selectorLibTest = await TestFactory.deploy();
        await selectorLibTest.waitForDeployment();

        return selectorLibTest as unknown as TestSelectorLib;
    }

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];
    });

    it("Should encode selector and get types", async function () {
        const libTest: TestSelectorLib = await loadFixture(deploySelectorLibTest);

        log("\nTS encoded:")

        const selectorTs = encodeDefaultSelector();
        log("Selector: ", selectorTs);

        const exCodeTs = encodeExecutionCode();
        log("exCode: ", exCodeTs, "\n");

        // redefine
        const testSelector = selector
        const testExCode = exCode

        const exCodeSlot = await libTest.testCode(testExCode);
        log("exCodeSlot after: ", exCodeSlot);
        expect(exCodeSlot).eq(exCodeTs);

        const selectorSlot = await libTest.testSelector(testSelector);
        log("selectorSlot after: ", selectorSlot);
        expect(selectorSlot).eq(selectorTs);

        const typeSelector = await libTest.getType(selectorSlot);
        log("type Selector after: ", typeSelector);
        expect(typeSelector).eq(0n);

        const typeExCode = await libTest.getType(exCodeSlot);
        log("type ExCode after: ", typeExCode);
        expect(typeExCode).eq(1n);
    });

    it("Should unmask slot", async function () {
        const libTest: TestSelectorLib = await loadFixture(deploySelectorLibTest);

        const unmasked = await libTest.getUnmasked(encodeDefaultSelector());
        log("Unmasked selector slot: ", unmasked);
        expect(unmasked).eq(encodeDefaultSelector());


        const unmaskedCode = await libTest.getUnmasked(encodeExecutionCode());
        log("Unmasked code slot: ", unmaskedCode);
        expect(unmaskedCode).eq("0x0000000000000000000000000000000000000000000000000000000000000001");

        const selectorGiven = selector
        const codeGiven = 1n
        const selectorPipelined = await libTest.pipelineSelector(selectorGiven);
        log(selectorPipelined)
        expect(selectorPipelined).eq(selectorGiven);

        const exCode = await libTest.pipelineExCode(1n);
        log(exCode)
        expect(exCode).eq(codeGiven);
    })
})