import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { Factory, Endpoint } from "../typechain-types"
import hre, { ethers, upgrades } from "hardhat";
import { main as deployFactory } from "../scripts/deploy/Factory"
import { loadDeploymentAddress, saveDeploymentAddress } from "../utils/fileUtils";
import { expect } from "chai";
import { BytesLike } from "ethers";
import { upgradeAny } from "../utils/upgradeUtils";
import { log } from "./testLogger" 

describe("Factory", function() {
    let factory: Factory;
    let owner: HardhatEthersSigner;
    let proxyAddr: string;

    let endpointComputed: string;
    let proxyComputed: string;

    let implSalt: string;
    let proxySalt: string;

    before(async() => {
        [owner] = await hre.ethers.getSigners()
        
        await deployFactory()

        const factoryAddr = loadDeploymentAddress("hardhat", "Factory")
        factory = await ethers.getContractAt("Factory", factoryAddr, owner)

        implSalt = ethers.keccak256(ethers.toUtf8Bytes("endpoint"))
        proxySalt = ethers.keccak256(ethers.toUtf8Bytes("proxy"))

        log("Impl salt: ", implSalt)
        log("Proxy salt: ", proxySalt, "\n")
    })

    it("should compute endpoint address", async function () {
        endpointComputed = await factory.computeImpl(implSalt)
        log("endpoint (impl) computed address: ", endpointComputed)

        proxyComputed = await factory.computeProxy(proxySalt, endpointComputed)
        log("proxy computed address: ", proxyComputed)
    })

    it("should deploy endpoint & proxies on computed addresses", async function () {
        const defConsRate = 5000
        const initAddr = [owner.address]
        let endpointAddr; 

        [endpointAddr, proxyAddr] = await factory.deploy.staticCall(defConsRate, implSalt, proxySalt, initAddr)
        log("endpoint = ", endpointAddr)
        log("proxy = ", proxyAddr)

        await factory.deploy(defConsRate, implSalt, proxySalt, initAddr)
        expect(endpointComputed).to.be.eq(endpointAddr)

        // for an upgrade test
        saveDeploymentAddress("hardhat", "Endpoint", proxyAddr, endpointAddr)
    })

    it("should force import and upgrade", async function () {
        const endpoint = await ethers.getContractFactory("Endpoint")

        await upgrades.forceImport(
            proxyAddr,
            endpoint,
            {
                kind: "uups"
            }
        )

        await upgradeAny("hardhat", "Endpoint")
    })
})