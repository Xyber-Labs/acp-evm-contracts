import { ethers } from "hardhat";
import { KeyStorage } from "../typechain-types";
import { deployKeyStorageFixture } from "./deploymentFixtures";
import { expect } from "chai";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { BigNumberish } from "ethers";



describe("KeyStorage", function() {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;
    let keystorage: KeyStorage;
    let keyTypes:BigNumberish[];
    let ownerKey: Uint8Array;
    const chainId = 1

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];
        // 0 - SIGNER   1 - EXECUTOR    2 - RECEIVER    3 - RESERVED
        keyTypes = [0, 1, 2, 3]

        keystorage = await deployKeyStorageFixture()
    });

    it("should add keys", async function() {
        // random bytes
        ownerKey = ethers.randomBytes(10)

        await keystorage.addKey(chainId, keyTypes[0], ownerKey)
        expect(await keystorage.hasKeys(owner.address, chainId, keyTypes)).to.be.eq(true)
    })

    it("should add batch of keys", async function() {
        let keys: Uint8Array[] = [];

        for (let i = 0; i < 4; i++) {
            keys[i] = ethers.randomBytes(10)
        }

        await keystorage.addKeyBatch(chainId, keyTypes, keys)
        expect(await keystorage.hasKeys(owner.address, chainId, keyTypes)).to.be.eq(true)
    })

    // only AgentRegistrator is permitted for this action 

    // it("should add keys for some agent", async function () {
    //     const userAddress = signers[0].address
    //     // let keys: Uint8Array<ArrayBufferLike>[] = [];
    //     let keys: Uint8Array[] = [];

    //     for (let i = 0; i < 4; i++) {
    //         keys[i] = ethers.randomBytes(10)
    //     }

    //     await keystorage.addKeysFor(userAddress, chainId, keyTypes, keys)
    //     expect(await keystorage.hasKeys(userAddress, chainId, keyTypes)).to.be.eq(true)
    // })

    it("should change keys", async function () {
        const newKey = ethers.randomBytes(10)

        await expect(keystorage.changeKey(chainId, keyTypes[0], ownerKey, newKey)).to.emit(keystorage, "KeySet")
    })

    it("should remove keys", async function () {
        await expect(keystorage.removeKey(chainId, keyTypes[0], ownerKey)).to.emit(keystorage, "KeyRemoved")
    })

    it("should change receiver", async function () {
        const receiver = ethers.randomBytes(10)

        await expect(keystorage.changeReceiver(chainId, receiver)).to.emit(keystorage, 'ReceiverChanged')
    })

    it("should revert if chainId = 0 for agents", async function () {
        let keys: Uint8Array[] = [];

        for (let i = 0; i < 4; i++) {
            keys[i] = ethers.randomBytes(10)
        }

        await expect(keystorage.addKey(0, keyTypes[0], ownerKey)).to.be.revertedWithCustomError(keystorage, "KeyStorage__InvalidChainID")
        await expect(keystorage.addKeyBatch(0, keyTypes, keys)).to.be.revertedWithCustomError(keystorage, "KeyStorage__InvalidChainID")
        await expect(keystorage.changeKey(0, keyTypes[0], keys[0], keys[1])).to.be.revertedWithCustomError(keystorage, "KeyStorage__InvalidChainID")
        await expect(keystorage.changeReceiver(0, keys[0])).to.be.revertedWithCustomError(keystorage, "KeyStorage__InvalidChainID")
        await expect(keystorage.removeKey(0, keyTypes[0], keys[0])).to.be.revertedWithCustomError(keystorage, "KeyStorage__InvalidChainID")
    })

})