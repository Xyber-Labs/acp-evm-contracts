import { ethers } from "hardhat";
import { log } from "./testLogger" 
import { WormholeMessageSender, WormholeMessageReceiver, Endpoint, WToken }  from "../typechain-types";
import { deployEndPointFixture } from "./deploymentFixtures";
import { getTestMsg, signConsensus } from "./testUtils";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { BytesLike } from "ethers";
import { expect } from "chai";


describe("Wormhole Messaging", function() {
    let relayer: Endpoint;
    let owner: HardhatEthersSigner;
    let signers: HardhatEthersSigner[];

    let wToken: WToken;

    const coder = ethers.AbiCoder.defaultAbiCoder();

    const amoyChainId = 80002n;
    const amouChainIdWHFormat = 5n;
    const sepoliaChainId = 11155111n;
    const sepoliaChainIdWHFormat = 2n;
    const amount = ethers.parseEther("1");

    const selector = "0x529dca32";
    const wormholeMessageId = "0x03";
    const bytes4 = ethers.hexlify(Buffer.from(selector.replace('0x', ''), 'hex'));
    const selectorSlot = ethers.zeroPadValue(bytes4, 32);

    beforeEach(async function() {
        signers = await ethers.getSigners();
        owner = signers[0];

        relayer = await deployEndPointFixture();
        
        const wTokenF = await ethers.getContractFactory("WToken");
        wToken = await wTokenF.deploy();

        await relayer.setATSConnector(owner.address);
        await relayer.setWrappedNative(wToken.target);

        await relayer.setChainIdForWormhole(
            [amouChainIdWHFormat, sepoliaChainIdWHFormat], 
            [amoyChainId, sepoliaChainId]
        );
    });

    it("Should allow Wormhole messaging", async function() {
        const sender = owner.address;
        const destAddress: string = ethers.ZeroAddress;

        const payload: BytesLike = coder.encode(
            ["string"],
            ["hello world"]
        );

        const gasLimit = 60000n;

        await expect(relayer["sendPayloadToEvm(uint16,address,bytes,uint256,uint256)"](
            amouChainIdWHFormat,
            destAddress,
            payload,
            0n,
            gasLimit, {
                value: amount
            }
        )).to.emit(relayer, "MessageProposed").withArgs(
            amoyChainId,
            amount,
            selectorSlot,
            coder.encode(["uint256", "uint256"], [0, gasLimit]),
            coder.encode(["address"], [sender]),
            coder.encode(["address"], [destAddress]),
            payload,
            wormholeMessageId
        )
    });

    it ("Should execute Wormhole message", async function() {
        const destChainID: string = amoyChainId.toString();

        let tx = await relayer.activateOrDisableSignerBatch(
            [await owner.getAddress(), signers[1], signers[2], signers[3], signers[4]],
            [true, true, true, true, true]
        )
        await tx.wait()

        tx = await relayer.activateOrDisableExecutorBatch(
            [await owner.getAddress(), signers[1], signers[2], signers[3], signers[4]],
            [true, true, true, true, true]
        )
        await tx.wait()

        const opData = await getTestMsg()

        const msg = "hello world"
        const randomSolidityAddress = ethers.ZeroAddress;
        const randomSolidityAddress_bytes = coder.encode(
            ["address"],
            [randomSolidityAddress]
        );
        let messageEncoded = coder.encode(["string"], [msg]);
        let addrEncoded = coder.encode(["address"], [owner.address]);
        let payload = coder.encode(
            ["bytes", "bytes"],
            [messageEncoded, addrEncoded]
        );
        let encoded_data = coder.encode(
            ["bytes32", "string", "string", "bytes"],
            [ethers.ZeroHash, destChainID, randomSolidityAddress_bytes, payload]
        );

        log("Initial data prepared")
        opData.initialProposal.payload = encoded_data
        opData.initialProposal.reserved = wormholeMessageId;

        const opSigners: any = [
            signers[1],
            signers[2],
            signers[3],
            signers[4]
        ];

        const sigs: any[] = await signConsensus(opSigners, opData);
        log(sigs)

        log("consensus created")
        let sigsFormatted = [];
        for (const sig of sigs) {
            const oneSigFormatted = ethers.Signature.from(sig);
            sigsFormatted.push(oneSigFormatted);
        }
        log(sigsFormatted)

        const sigsEncoderF = await ethers.getContractFactory("SigsEncoderMock")
        const sigsEncoder = await sigsEncoderF.deploy()
        const packedSigs = await sigsEncoder.encode(sigs)

        const packedSigsWithLib = await sigsEncoder.encodeWithLib(sigs)
        expect(packedSigsWithLib).to.be.eq(packedSigs);

        await relayer.setSupersData(
            [signers[9].address],
        );    

        const superSig = await signConsensus([signers[9]], opData)
        const sigStruct = ethers.Signature.from(superSig[0]);    

        await expect(relayer.execute(opData, [sigStruct], packedSigs)).to.emit(relayer, "WormholeMessageExecution");
    });


    describe("Wormhole Example Messanger", function() {
        let sender: WormholeMessageSender;
        let receiver: WormholeMessageReceiver;

        const testMessage: string = "Testing123";

        beforeEach(async function() {
            const Receiver = await ethers.getContractFactory("WormholeMessageReceiver");
            receiver = await Receiver.deploy(relayer.target);
            await receiver.waitForDeployment();

            const Sender = await ethers.getContractFactory("WormholeMessageSender");
            sender = await Sender.deploy(relayer.target);
            await sender.waitForDeployment();

            await receiver.setRegisteredSender(sepoliaChainIdWHFormat, ethers.zeroPadValue(sender.target.toString(), 32))
        });

        it("Should successfully trigger interchain tx", async function() {
            const payload = coder.encode(['string', 'address'], [testMessage, owner.address]);

            const cost = await sender.quoteCrossChainCost(amouChainIdWHFormat);

            await expect(sender.sendMessage(amouChainIdWHFormat, receiver.target, testMessage, {
                value: cost
            })).to.emit(relayer, "MessageProposed").withArgs(
                amoyChainId,
                cost,
                selectorSlot,
                coder.encode(["uint256", "uint256"], [0, await sender.GAS_LIMIT()]),
                coder.encode(["address"], [sender.target]),
                coder.encode(["address"], [receiver.target]),
                payload,
                wormholeMessageId
            );
        });

        it("Should receive message on destination chain", async function() {
            const messageBefore = await receiver.message();
            expect(messageBefore).to.equal('');

            let tx = await relayer.activateOrDisableSignerBatch(
                [await owner.getAddress(), signers[1], signers[2], signers[3], signers[4]],
                [true, true, true, true, true]
            )
            await tx.wait();
    
            tx = await relayer.activateOrDisableExecutorBatch(
                [await owner.getAddress(), signers[1], signers[2], signers[3], signers[4]],
                [true, true, true, true, true]
            )
            await tx.wait();
        
            let payload = coder.encode(
                ["string", 'address'],
                [testMessage, owner.address]
            );

            const transmitterParams = {
                blockFinalizationOption: 0n,
                customGasLimit: 200000n,
            };        
    
            const proposal = {
                destChainId: 31337n,
                nativeAmount: 10000n,
                selectorSlot: selectorSlot,
                senderAddr: coder.encode(["address"], [sender.target]),
                destAddr: coder.encode(
                    ["address"],
                    [receiver.target]
                ),
                payload: payload,
                reserved: wormholeMessageId,
                transmitterParams: coder.encode(
                    ["uint256", "uint256"],
                    [transmitterParams.blockFinalizationOption, transmitterParams.customGasLimit]
                )
            };

            const txIdTestPack: BytesLike = coder.encode(
                ["uint256"],
                ["111"]
            )
            const srcChainData = {
                location: (sepoliaChainId << 128n) + 111n,
                srcOpTxId: [txIdTestPack, txIdTestPack],
            };
            
            const opData = {
                initialProposal: proposal,
                srcChainData: srcChainData,
            };      
                        
            const opSigners: any = [
                signers[1],
                signers[2],
                signers[3],
                signers[4]
            ];
    
            const sigs: any[] = await signConsensus(opSigners, opData);
            log(sigs)
    
            let sigsFormatted = [];
            for (const sig of sigs) {
                const oneSigFormatted = ethers.Signature.from(sig);
                sigsFormatted.push(oneSigFormatted);
            }
            log(sigsFormatted)
    
            const sigsEncoderF = await ethers.getContractFactory("SigsEncoderMock")
            const sigsEncoder = await sigsEncoderF.deploy()
            const packedSigs = await sigsEncoder.encode(sigs)
    
            const packedSigsWithLib = await sigsEncoder.encodeWithLib(sigs)
            expect(packedSigsWithLib).to.be.eq(packedSigs);

            await relayer.setSupersData(
                [signers[9].address],
            );    
    
            const superSig = await signConsensus([signers[9]], opData)
            const sigStruct = ethers.Signature.from(superSig[0]);        
    
            // @ts-ignore
            await expect(relayer.execute(opData, [sigStruct], packedSigs)).to.emit(relayer, "WormholeMessageExecution");

            const messageAfter = await receiver.message();
            expect(messageAfter).to.equal(testMessage);
        });
    });
});