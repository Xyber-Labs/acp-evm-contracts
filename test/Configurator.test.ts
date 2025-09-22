import hre, { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { BytesLike } from "ethers";
import { deployUpgradeable, logDeploymentData } from "../utils/deployUtils";
import { saveDeploymentAddress } from "../utils/fileUtils";
import { expect } from "chai";
import { Configurator, Endpoint } from "../typechain-types";
import { log } from "./testLogger";
import { OriginLib } from "../typechain-types/contracts/endpoint/Configurator";

describe("Endpoint configurator", function () {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;

    let conf: Configurator;
    let ep: Endpoint;

    const coder = ethers.AbiCoder.defaultAbiCoder();

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];

        const netname = hre.network.name;

        const factoryEndpoint = "Endpoint";
        const factoryConf = "Configurator";

        const consensus = 50 * 100;

        const argsEndpoint = [[await owner.getAddress()], consensus, 31337];
    
        // @ts-ignore
        ep = await deployUpgradeable(factoryEndpoint, argsEndpoint);
    
        let { address, implAddress } = await logDeploymentData(
            factoryEndpoint,
            ep
        );

        const argsConf: any = [[await owner.getAddress(), address]];
        // @ts-ignore
        conf = await deployUpgradeable(factoryConf, argsConf);
    
        const { address: confAddress, implAddress: confImplAddress } = await logDeploymentData(
            factoryConf,
            conf
        );

        await ep.setConfigurator(confAddress)

        await ep.grantRole(
            await ep.CONFIG(),
            confAddress
        )
    });

    it("Should set new configs", async function () {

        // PAYLOAD
        const newConsensusRate = 6666;
        const newParticipantLen = 5;

        const newSigners = [
            signers[1].address,
            signers[2].address,
            signers[3].address
        ]

        const newExecutors = [
            signers[3].address,
            signers[4].address,
            signers[5].address,
        ]

        const signerFlags = [
            true, 
            true,
            true
        ]

        const executorFlags = [
            true, 
            true,
            true
        ]

        const payload = coder.encode(
            [
                "uint256", 
                "uint256", 
                "address[]",
                "address[]",
                "bool[]",
                "bool[]"
            ],
            [
                newConsensusRate, 
                newParticipantLen,
                newSigners,
                newExecutors,
                signerFlags,
                executorFlags
            ]
        )

        log("Payload:", payload)

        // CALLDATA
        const srcChain = 1
        const sender20: BytesLike = await owner.getAddress()
        const senderContract = coder.encode(["address"], [sender20])
        const srcTxHash = coder.encode(['string'], ["src tx hash"])
        const msg = coder.encode(
            ["uint256", "bytes", "bytes", "bytes"],
            [srcChain, srcTxHash, senderContract, payload]
        )
        log("\nCalldata ready: ", msg)


        // allow origin
        const origin: OriginLib.OriginStruct = {
            contractAddress: senderContract,
            chainId: srcChain
        }
        await conf.populateAllowedOrigins(
            [
                origin
            ]
        )
        log("Origin added")


        // fake endpoint
        const role = await conf.ENDPOINT();
        await conf.grantRole(role, owner.address)
        log("Endpoint added")


        // execute
        await expect(conf.execute(msg)).to.emit(conf, "NewRound").withArgs(
            2n, 6666n, 5n
        )


        // VERIFY DATA
        const roundData = await conf.roundData(2n)
        log(roundData)

        expect(roundData[1]).to.be.eq(6666n)
        expect(roundData[2]).to.be.eq(5n)

        const allowed1 = await ep.allowedSigners(signers[1].address)
        const allowed2 = await ep.allowedSigners(signers[2].address)

        expect(allowed1).to.be.true
        expect(allowed2).to.be.true

        const allowed3 = await ep.allowedExecutors(signers[3].address)
        const allowed4 = await ep.allowedExecutors(signers[4].address)
        const allowed5 = await ep.allowedExecutors(signers[5].address)

        expect(allowed3).to.be.true
        expect(allowed4).to.be.true
        expect(allowed5).to.be.true
    });
});
