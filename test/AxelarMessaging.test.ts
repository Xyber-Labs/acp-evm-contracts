import { ethers } from "hardhat";
import { log } from "./testLogger" 
import { AxelarExampleMessanger, Endpoint, TokenMock }  from "../typechain-types";
import { deployEndPointFixture } from "./deploymentFixtures";
import { getTestMsg, signConsensus } from "./testUtils";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { BytesLike, Contract } from "ethers";
import { expect } from "chai";
import { deployUpgradeable } from "../utils/deployUtils";

describe("Axelar Messaging", function() {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;
    let endpoint: Endpoint;
    let gasEstimator: Contract;
    let DFOracle: Contract;
    let token: TokenMock;

    const coder = ethers.AbiCoder.defaultAbiCoder();
    
    const opbnb = "opbnb";
    const amoy = "Polygon Amoy";
    const hardhat = "hardhat"
    const opbnbChainId = 5611n;
    const amoyChainId = 80002n;
    const hardhatChainId = 31337n;
    const opbnbNativeKey = "0x4100000000000000000000000000000000000000000000000000000000000000"
    const opbnbGasKey = "0x4110000000000000000000000000000000000000000000000000000000000000"
    const amoyNativeKey = "0x5100000000000000000000000000000000000000000000000000000000000000"
    const amoyGasKey = "0x5110000000000000000000000000000000000000000000000000000000000000"
    const hardhatNativeKey = "0x6100000000000000000000000000000000000000000000000000000000000000"
    const hardhatGasKey = "0x6110000000000000000000000000000000000000000000000000000000000000"
    
    const amount = ethers.parseEther("100");

    const selector = "0x49160658";
    const axelarMessageId = "0x01";
    const bytes4 = ethers.hexlify(Buffer.from(selector.replace('0x', ''), 'hex'));
    const selectorSlot = ethers.zeroPadValue(bytes4, 32);

    beforeEach(async function() {
        signers = await ethers.getSigners();
        owner = signers[0];

        endpoint = await deployEndPointFixture();        
        gasEstimator = await deployUpgradeable("GasEstimator", [[owner.address, endpoint.target]])
        DFOracle = await deployUpgradeable("DFOracleMock", [[owner.address]])

        const tokenF = await ethers.getContractFactory("TokenMock");
        token = await tokenF.deploy();

        // endpoint setup
        await endpoint.setATSConnector(owner.address);
        await endpoint.setWrappedNative(token.target);
        await endpoint.setChainsForAxelar([opbnb, amoy, hardhat], [opbnbChainId, amoyChainId, hardhatChainId]);
        await endpoint.setGasEstimator(await gasEstimator.getAddress())
        await endpoint.setSupersData(
            [signers[9].address],
        );
        await endpoint.setTotalActiveSigners(1)
        let tx = await endpoint.activateOrDisableSignerBatch(
            [await owner.getAddress(), signers[1], signers[2], signers[3], signers[4]],
            [true, true, true, true, true]
        )
        await tx.wait()
        tx = await endpoint.activateOrDisableExecutorBatch(
            [await owner.getAddress(), signers[1], signers[2], signers[3], signers[4]],
            [true, true, true, true, true]
        )
        await tx.wait()

        // DFOracleMock setup
        await DFOracle.setLatestUpdate(opbnbNativeKey, 10)
        await DFOracle.setLatestUpdate(opbnbGasKey, 10)
        await DFOracle.setLatestUpdate(amoyNativeKey, 20)
        await DFOracle.setLatestUpdate(amoyGasKey, 20)
        await DFOracle.setLatestUpdate(hardhatNativeKey, 30)
        await DFOracle.setLatestUpdate(hardhatGasKey, 30)

        // GasEstimator setup
        await gasEstimator.setChainData(opbnbChainId, {
            totalFee: 10,
            decimals: 18,
            defaultGas: 1000,
            gasDataKey: opbnbGasKey,
            nativeDataKey: opbnbNativeKey
        })
        await gasEstimator.setChainData(amoyChainId, {
            totalFee: 10,
            decimals: 18,
            defaultGas: 1000,
            gasDataKey: amoyGasKey,
            nativeDataKey: amoyNativeKey
        })
        await gasEstimator.setChainData(hardhatChainId, {
            totalFee: 10,
            decimals: 18,
            defaultGas: 1000,
            gasDataKey: hardhatGasKey,
            nativeDataKey: hardhatNativeKey
        })
        await gasEstimator.setDFOracle(await DFOracle.getAddress())
    });

    it("Should allow Axelar messaging", async function() {
        const sender = owner.address;
        const destChainName: string = "Polygon Amoy";
        const destChainBytes = ethers.keccak256(ethers.solidityPacked(["string"], [destChainName]))
        const destChainId = await endpoint.chainNameToChainID(destChainBytes)
        const destAddress: string = ethers.ZeroAddress;

        const payload: BytesLike = coder.encode(
            ["string"],
            ["hello world"]
        );

        const executionGasLimit = 60000n;
        const estimateOnChain = false;
        const refundAddress = owner.address;
        const params: BytesLike = ethers.ZeroHash;
        const amountReceived = await gasEstimator.estimateExecutionWithGas(destChainId, executionGasLimit)

        await expect(endpoint.payGas(
            sender,
            destChainName,
            destAddress,
            payload,
            executionGasLimit,
            estimateOnChain,
            refundAddress,
            params, {
                value: amount
            }
        )).to.emit(endpoint, "MessageProposed").withArgs(
            amoyChainId,
            amountReceived,
            selectorSlot,
            coder.encode(["uint256", "uint256"], [0, executionGasLimit]),
            coder.encode(["address"], [sender]),
            coder.encode(["address"], [destAddress]),
            payload,
            axelarMessageId
        )

        await expect(endpoint.callContract(
            destChainName,
            destAddress,
            payload
        )).to.emit(endpoint, "ContractCall");
    });

    it ("Should execute Axelar message", async function() {
        const destChainID: string = amoyChainId.toString();

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
        opData.initialProposal.reserved = axelarMessageId;

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

        const packedSigsWithLib = await sigsEncoder.encodeWithLib(sigs);
        expect(packedSigsWithLib).to.be.eq(packedSigs);

        const superSig = await signConsensus([signers[9]], opData)
        const sigStruct = ethers.Signature.from(superSig[0]);

        await expect(endpoint.execute(opData, [sigStruct], packedSigs)).to.emit(endpoint, "AxelarMessageExecution");
    });


    describe("Axelar Example Protocol Test", function() {
        let axelarExampleMessanger: AxelarExampleMessanger;
        const testMessage: string = "Testing123";

        beforeEach(async function() {
            const AxelarExampleMessanger = await ethers.getContractFactory("AxelarExampleMessanger");
            axelarExampleMessanger = await AxelarExampleMessanger.deploy(endpoint.target, endpoint.target);
            await axelarExampleMessanger.waitForDeployment();
        });

        it('Should set correct gateway and gas service addresses on src chain', async () => {
            expect(await axelarExampleMessanger.gateway()).to.equal(endpoint.target);
            expect(await axelarExampleMessanger.gasService()).to.equal(endpoint.target);
        });

        it("Should estimate gas", async function() {
            const cost = await axelarExampleMessanger.estimateGasFee(opbnb, owner.address, "hello-world");

            expect(cost).to.not.be.eq(0)
        });    

        it('Should successfully trigger interchain tx', async () => {
            const destChainBytes = ethers.keccak256(ethers.solidityPacked(["string"], [amoy]))
            const destChainId = await endpoint.chainNameToChainID(destChainBytes)
            const amountReceived = await gasEstimator.estimateExecutionWithGas(destChainId, await axelarExampleMessanger.GAS_LIMIT())
        
            const payload = coder.encode(['string'], [testMessage]);
                    
            await expect(axelarExampleMessanger.setRemoteValue(amoy, axelarExampleMessanger.target.toString(), testMessage, {
                value: amount,
            })).to.emit(endpoint, "MessageProposed").withArgs(
                amoyChainId,
                amountReceived,
                selectorSlot,
                coder.encode(["uint256", "uint256"], [0, await axelarExampleMessanger.GAS_LIMIT()]),
                coder.encode(["address"], [axelarExampleMessanger.target]),
                coder.encode(["address"], [axelarExampleMessanger.target]),
                payload,
                axelarMessageId
            );
        });

        it('Should receive message on destination chain', async () => {
            const messageBefore = await axelarExampleMessanger.message();
            expect(messageBefore).to.equal('');

            let tx = await endpoint.activateOrDisableSignerBatch(
                [await owner.getAddress(), signers[1], signers[2], signers[3], signers[4]],
                [true, true, true, true, true]
            )
            await tx.wait();
    
            tx = await endpoint.activateOrDisableExecutorBatch(
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
                senderAddr: coder.encode(["address"], [axelarExampleMessanger.target]),
                destAddr: coder.encode(
                    ["address"],
                    [axelarExampleMessanger.target]
                ),
                payload: payload,
                reserved: axelarMessageId,
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

            await endpoint.setSupersData(
                [signers[9].address],
            );    

            const superSig = await signConsensus([signers[9]], opData)
            const sigStruct = ethers.Signature.from(superSig[0]);    
    
            // @ts-ignore
            await expect(endpoint.execute(opData, [sigStruct], packedSigs)).to.emit(endpoint, "AxelarMessageExecution");

            const messageAfter = await axelarExampleMessanger.message();
            expect(messageAfter).to.equal(testMessage);
        });
    })
});
