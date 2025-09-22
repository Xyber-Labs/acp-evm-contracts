import { ethers } from "hardhat";
import { expect } from "chai";
import { LocationMock } from "../typechain-types";
import { log } from "./testLogger";

describe("Location lib test", function() {

    let lib: LocationMock;
    let packedVar: bigint;
    let srcChainId: bigint = 31337n;
    let srcBlockNumber: bigint = 20n

    before(async() => {
        const mockFactory = await ethers.getContractFactory("LocationMock")
        const mock = await mockFactory.deploy()
        lib = mock
    })

    it("should pack vars", async function () {
        const expectedPackedVar = (srcChainId << 128n) + srcBlockNumber

        const res = await lib.testPack(srcChainId, srcBlockNumber)
        log(res)
        expect(expectedPackedVar).to.be.eq(res)

        packedVar = res
    })

    it("should unpack vars", async function () {
        const res = await lib.testUnpack(packedVar)
        log(res)

        expect(res[0]).to.be.eq(srcChainId)
        expect(res[1]).to.be.eq(srcBlockNumber)
    })

    it("should get chain id", async function() {
        const res = await lib.getChainId(packedVar)
        log(res)

        expect(res).to.be.eq(srcChainId)
    })

    it("should get block", async function () {
        const res = await lib.getBlock(packedVar)
        log(res)

        expect(res).to.be.eq(srcBlockNumber)
    })

})