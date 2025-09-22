
import { ethers } from "hardhat";
import { log } from "./testLogger" 
import { Endpoint, WToken, ILZAdapter, LZExampleMessenger, DFAdapter }  from "../typechain-types";
import { deployEndPointFixture } from "./deploymentFixtures";
import { getTestMsg, signConsensus } from "./testUtils";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { BytesLike } from "ethers";
import { expect } from "chai";
import { deployUpgradeable } from "../utils/deployUtils";
import { main as deployOracle } from "../scripts/deploy/DFOracleMock"
import { main as deployEstimator } from "../scripts/deploy/GasEstimator"
import { SignatureLib } from "../typechain-types/contracts/Master";


describe("LayerZero Messaging", function() {
    let relayer: Endpoint;
    let owner: HardhatEthersSigner;
    let signers: HardhatEthersSigner[];
    let superAgent: HardhatEthersSigner

    let wToken: WToken;
    let DFAdapter;
    let estimator;
    let oracle;

    const coder = ethers.AbiCoder.defaultAbiCoder();

    const amoyChainId = 80002n;
    const amoyEid = 40267n;
    const sepoliaChainId = 11155111n;
    const sepoliaEid = 40161n;
    const hardhatChainId = 31337n
    const hardhatEid = 1337n;
    const amount = ethers.parseEther("1");
    const options = "0x000000000000000000000000000F4240"        // 1000000 in hex
    const payInLz = false

    const selector = "0x13137d65";
    const lzMessageId = "0x02";
    const bytes4 = ethers.hexlify(Buffer.from(selector.replace('0x', ''), 'hex'));
    const selectorSlot = ethers.zeroPadValue(bytes4, 32);

    const amoyDataKey = ethers.randomBytes(32)
    const amoyGasDataKey = ethers.randomBytes(32)
    const sepoliaDataKey = ethers.randomBytes(32)
    const sepoliaGasDataKey = ethers.randomBytes(32)
    const hardhatDataKey = ethers.randomBytes(32)
    const hardhatGasDataKey = ethers.randomBytes(32)

    beforeEach(async function() {
        signers = await ethers.getSigners();
        owner = signers[0];
        superAgent = signers[10]
        
        // polygon_amoy, ethereum_sepolia
        const eids = [amoyEid, sepoliaEid, hardhatEid] 
        const chainIds = [amoyChainId, sepoliaChainId, hardhatChainId]

        relayer = await deployEndPointFixture();
        
        const wTokenF = await ethers.getContractFactory("WToken");
        wToken = await wTokenF.deploy();

        const factoryName = "DFAdapter";
        const args: any = [[owner.address]];
        DFAdapter = await deployUpgradeable(factoryName, args);

        const oracleAddr = await deployOracle()
        oracle = await ethers.getContractAt("DFOracleMock", oracleAddr)

        const estAddr = await deployEstimator()
        estimator = await ethers.getContractAt("GasEstimator", estAddr)

        await relayer.setATSConnector(owner.address);
        await relayer.setWrappedNative(wToken.target);
        await relayer.setLzEids(eids, chainIds)
        await relayer.setGasEstimator(estAddr)
        await relayer.setTotalActiveSigners(3)
        await relayer.setSupersData([superAgent.address])
    
        await estimator.setDFOracle(oracleAddr)
        await estimator.setDeviations(5, 10, 15)
        await estimator.setChainDataBatch([amoyChainId, sepoliaChainId, hardhatChainId], [
            {
                totalFee: 10,
                decimals: 18,
                defaultGas: 10,
                gasDataKey: amoyGasDataKey,
                nativeDataKey: amoyDataKey
            },
            {
                totalFee: 10,
                decimals: 18,
                defaultGas: 10,
                gasDataKey: sepoliaGasDataKey,
                nativeDataKey: sepoliaDataKey
            },
            {
                totalFee: 10,
                decimals: 18,
                defaultGas: 10,
                gasDataKey: hardhatGasDataKey,
                nativeDataKey: hardhatDataKey
            },
        ])

        await oracle.setLatestUpdate(amoyDataKey, 1)
        await oracle.setLatestUpdate(amoyGasDataKey, 2)
        await oracle.setLatestUpdate(sepoliaDataKey, 3)
        await oracle.setLatestUpdate(sepoliaGasDataKey, 4)
        await oracle.setLatestUpdate(hardhatDataKey, 5)
        await oracle.setLatestUpdate(hardhatGasDataKey, 6)
    });

    it("Should allow LayerZero messaging", async function() {
        const destAddress = ethers.zeroPadValue(signers[1].address, 32)
        const payload: BytesLike = coder.encode(
            ["string"],
            ["hello world"]
        );

        const gasLimit = 60000n;

        const lzMessagingParams = {
            dstEid: amoyEid,
            receiver: destAddress,
            message: payload, 
            options: options,
            payInLzToken: payInLz
        }

        await expect(relayer.send(
            lzMessagingParams,
            owner.address,
            {
                value: amount
            }
        )).to.emit(relayer, "MessageProposed")
    });

    it ("Should execute LayerZero message", async function() {
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
        opData.initialProposal.reserved = lzMessageId;
        opData.initialProposal.destChainId = hardhatChainId

        const opSigners: any = [
            signers[1],
            signers[2],
            signers[3],
            signers[4]
        ];

        const transmitterSigs: any[] = await signConsensus(opSigners, opData);
        log(transmitterSigs)

        const sigsEncoderF = await ethers.getContractFactory("SigsEncoderMock")
        const sigsEncoder = await sigsEncoderF.deploy()
        const transmittersPackedSigs = await sigsEncoder.encode(transmitterSigs)
        const packedSigsWithLib = await sigsEncoder.encodeWithLib(transmitterSigs)
        expect(packedSigsWithLib).to.be.eq(transmittersPackedSigs)

        log("consensus created")

        const [superSig] = await signConsensus([superAgent], opData)
        const superSigFormatted = {
            v: parseInt(superSig.slice(130, 132), 16),
            r: "0x" + superSig.slice(2, 66),
            s: "0x" + superSig.slice(66, 130)
        }

        await expect(relayer.execute(
            opData, 
            [superSigFormatted], 
            transmittersPackedSigs,
            { value: amount }
        )).to.emit(relayer, "LZMessageExecution");
    });


    describe("LayerZero Example Messanger", function() {
        let sender: LZExampleMessenger;
        let receiver: LZExampleMessenger;

        const testMessage: string = "Testing123";


        beforeEach(async function() {
            const Receiver = await ethers.getContractFactory("LZExampleMessenger");
            receiver = await Receiver.deploy(relayer.target, owner.address);
            await receiver.waitForDeployment();

            const Sender = await ethers.getContractFactory("LZExampleMessenger");
            sender = await Sender.deploy(relayer.target, owner.address);
            await sender.waitForDeployment();

            await sender.setPeer(amoyEid, coder.encode(
                ["address"],
                [await owner.getAddress()]
            ));
            await sender.setPeer(hardhatEid, coder.encode(
                ["address"],
                [await owner.getAddress()]
            ));

            await receiver.setPeer(amoyEid, coder.encode(
                ["address"],
                [await owner.getAddress()]
            ));
            await receiver.setPeer(hardhatEid, coder.encode(
                ["address"],
                [await owner.getAddress()]
            ));
        });

        it("Should successfully trigger interchain tx", async function() {

            const params = {
                dstEid: sepoliaEid,
                receiver: ethers.zeroPadValue(await receiver.getAddress(), 32),
                message: coder.encode(
                    ["string"],
                    [testMessage]
                ),
                options: options,
                payInLzToken: false
            }
            
            const cost = await relayer.quote(params, await sender.getAddress());
            
            await expect(sender.send(amoyEid, testMessage, options, {
                value: amount
            })).to.emit(relayer, "MessageProposed")
        });

        it("Should receive message on destination chain", async function() {
            const messageBefore = await receiver.data();
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
                ["string"],
                [testMessage]
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
                reserved: lzMessageId,
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
                location: (amoyChainId << 128n) + 111n,
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

            const transmitterSigs: any[] = await signConsensus(opSigners, opData);

            const sigsEncoderF = await ethers.getContractFactory("SigsEncoderMock")
            const sigsEncoder = await sigsEncoderF.deploy()
            const transmittersPackedSigs = await sigsEncoder.encode(transmitterSigs)
            const packedSigsWithLib = await sigsEncoder.encodeWithLib(transmitterSigs)
            expect(packedSigsWithLib).to.be.eq(transmittersPackedSigs)

            log("consensus created")

            const [superSig] = await signConsensus([superAgent], opData)
            const superSigFormatted = {
                v: parseInt(superSig.slice(130, 132), 16),
                r: "0x" + superSig.slice(2, 66),
                s: "0x" + superSig.slice(66, 130)
            }
    
            await expect(relayer.execute(
                //@ts-ignore
                opData, 
                [superSigFormatted], 
                transmittersPackedSigs,
                { value: amount }
            )).to.emit(relayer, "LZMessageExecution");

            await relayer.execute(
                //@ts-ignore
                opData, 
                [superSigFormatted], 
                transmittersPackedSigs,
                { value: amount }
            )

            const messageAfter = await receiver.data();
            expect(messageAfter).to.equal(testMessage);
        });
    });
});