import { ethers, upgrades } from "hardhat";
import { log } from "./testLogger" 
import { 
    Endpoint,
    AgentParamsEncoderMock,
    TokenMock,
    MessageRepeater,
    Master,
    ChainInfo,
    MessageData,
    ExecutorLottery,
    GasEstimator
}  from "../typechain-types";
import { deployEndPointFixture } from "./deploymentFixtures";
import { main as deployMessageRepeater } from "../scripts/deploy/MessageRepeater";
import { getTestMsg, encodeDefaultSelector, signConsensus, getPrefixedMsg } from "./testUtils";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { BigNumberish, BytesLike, Contract, dataLength, EtherSymbol } from "ethers";
import { expect } from "chai";
import { deployUpgradeable } from "../utils/deployUtils";


describe("Endpoint", function () {
    let signers: HardhatEthersSigner[];
    let owner: HardhatEthersSigner;
    let endpoint: Endpoint;
    let estimator: Contract;
    let DFOracle: Contract;
    let agentParamsEncoderMock: AgentParamsEncoderMock;
    let token: TokenMock;
    const coder = ethers.AbiCoder.defaultAbiCoder()

    const hardhatId = 31337
    const hardhatNativeKey = "0x6100000000000000000000000000000000000000000000000000000000000000"
    const hardhatGasKey = "0x6110000000000000000000000000000000000000000000000000000000000000"
    const testChainId = 1
    const testNativeKey = "0x9100000000000000000000000000000000000000000000000000000000000000"
    const testGasKey = "0x9110000000000000000000000000000000000000000000000000000000000000"
    

    before(async () => {
        signers = await ethers.getSigners();
        owner = signers[0];

        endpoint = await deployEndPointFixture()
        estimator = await deployUpgradeable("GasEstimator", [[owner.address, endpoint.target]])
        DFOracle = await deployUpgradeable("DFOracleMock", [[owner.address]])

        await endpoint.setGasEstimator(estimator.target)
        await endpoint.setTotalActiveSigners(1)
        await estimator.setDFOracle(DFOracle.target)
        await estimator.setChainDataBatch([hardhatId, testChainId], [
            {
                totalFee: 10,
                decimals: 18,
                defaultGas: 10,
                gasDataKey: hardhatGasKey,
                nativeDataKey: hardhatNativeKey
            },
            {
                totalFee: 10,
                decimals: 18,
                defaultGas: 10,
                gasDataKey: testGasKey,
                nativeDataKey: testNativeKey
            }
        ])
        await DFOracle.setLatestUpdate(hardhatNativeKey, 10)
        await DFOracle.setLatestUpdate(hardhatGasKey, 100)
        await DFOracle.setLatestUpdate(testNativeKey, 29)
        await DFOracle.setLatestUpdate(testGasKey, 210)

        const encoderF = await ethers.getContractFactory("AgentParamsEncoderMock")
        agentParamsEncoderMock = await encoderF.deploy()

        const tokenF = await ethers.getContractFactory("TokenMock")
        token = await tokenF.deploy()

    });

    it("Should propose operation", async function () {
       // PROPOSE
       const coder = ethers.AbiCoder.defaultAbiCoder();

       // messenger address
       const destAddress: BytesLike = coder.encode(
           ["address"], 
           [ethers.ZeroAddress]
       ); 
       const selectorSlot: BytesLike = encodeDefaultSelector();
       const agentParams = {
           waitForBlocks: 3,
           customGasLimit: 40,
       };
       const params: BytesLike = coder.encode(
           ["string"],
           ["hello world"]
       );
       log("Selector slot:", selectorSlot);


       const encodedAgentParams = await agentParamsEncoderMock.encode(agentParams.waitForBlocks, agentParams.customGasLimit)

       const minValue = await estimator.estimateExecutionWithGas(testChainId, 10000)
       
       await endpoint.setATSConnector(signers[1].address)
       await endpoint.setWrappedNative(await token.getAddress())
       
       await endpoint.propose(
           testChainId,
           selectorSlot,
           encodedAgentParams,
           destAddress,
           params,
           { value: minValue + 1n}
       );
    });

    it("Should setup supers", async function () {
        await endpoint.setSupersData(
            [signers[9].address],
        )
    })

    it("should revert if msg.value in propose < minCommission", async function () {
        await endpoint.setMinCommission(100);
        
        const coder = ethers.AbiCoder.defaultAbiCoder();

        // messenger address
        const destAddress: BytesLike = coder.encode(
            ["address"], 
            [ethers.ZeroAddress]
        ); 
        const selectorSlot: BytesLike = encodeDefaultSelector();
        const agentParams = {
            waitForBlocks: 3,
            customGasLimit: 40,
        };
        const params: BytesLike = coder.encode(
            ["string"],
            ["hello world"]
        );
        log("Selector slot:", selectorSlot);


        const encodedAgentParams = await agentParamsEncoderMock.encode(agentParams.waitForBlocks, agentParams.customGasLimit)

        await endpoint.setATSConnector(signers[1].address)
        await endpoint.setWrappedNative(await token.getAddress())
        
        await expect(endpoint.propose(
            testChainId,
            selectorSlot,
            encodedAgentParams,
            destAddress,
            params,
            { value: 1 }
        )).to.be.revertedWithCustomError(endpoint, "Endpoint__InvalidCommission")
    })

    it("Should revert if propose is rejected", async function () {
        // PROPOSE
        await endpoint.setRejects(true, false)

        const coder = ethers.AbiCoder.defaultAbiCoder();

        const destChainID: BigNumberish = 1;
        // messenger address
        const destAddress: BytesLike = coder.encode(
            ["address"], 
            [ethers.ZeroAddress]
        ); 
        const selectorSlot: BytesLike = encodeDefaultSelector();
        const agentParams = {
            waitForBlocks: 3,
            customGasLimit: 40,
        };
        const params: BytesLike = coder.encode(
            ["string"],
            ["hello world"]
        );
        log("Selector slot:", selectorSlot);


        const encodedAgentParams = await agentParamsEncoderMock.encode(agentParams.waitForBlocks, agentParams.customGasLimit)

        await endpoint.setATSConnector(signers[1].address)
        await endpoint.setWrappedNative(await token.getAddress())
        
        await expect(endpoint.propose(
            destChainID,
            selectorSlot,
            encodedAgentParams,
            destAddress,
            params,
            { value: 200 }
        )).to.be.revertedWithCustomError(endpoint, "Endpoint__ProposeReject")
    })

    it("Should revert if execute is rejected", async function () {
        // EXECUTE
        await endpoint.setRejects(false, true)

        const coder = ethers.AbiCoder.defaultAbiCoder();
        const destChainID: BigNumberish = 1;

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



        const opData = await getTestMsg()

        // pack calldata for msgr in payload
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
            ["uint256", "bytes", "bytes"],
            [destChainID, randomSolidityAddress_bytes, payload]
        );

        log("Initial data prepared")
        opData.initialProposal.payload = encoded_data

        const opSigners: any = [
            signers[1],
            signers[2],
            signers[3],
            signers[4],
            // signers[5],
            // signers[6],
        ];

        // log(opToSign)
        const sigs: any[] = await signConsensus(opSigners, opData);
        log(sigs)

        log("consensus created")
        let sigsFormatted = [];
        for (const sig of sigs) {
            // get v, r, s
            const oneSigFormatted = ethers.Signature.from(sig);
            sigsFormatted.push(oneSigFormatted);
        }
        log(sigsFormatted)

        const sigsEncoderF = await ethers.getContractFactory("SigsEncoderMock")
        const sigsEncoder = await sigsEncoderF.deploy()
        const packedSigs = await sigsEncoder.encode(sigs)

        const packedSigsWithLib = await sigsEncoder.encodeWithLib(sigs)
        expect(packedSigsWithLib).to.be.eq(packedSigs)

        const superSig = await signConsensus([signers[9]], opData)
        const sigStruct = ethers.Signature.from(superSig[0]);

        await expect(endpoint.execute(opData, [sigStruct], packedSigs))
            .to.be.revertedWithCustomError(endpoint, "Endpoint__ExecuteReject")
        
        await endpoint.setRejects(false, false)
    })

    it("Should execute operation", async function () {
        // EXECUTE
        const coder = ethers.AbiCoder.defaultAbiCoder();
        const destChainID: BigNumberish = 1;

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



        const opData = await getTestMsg()

        // pack calldata for msgr in payload
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
            ["uint256", "bytes", "bytes"],
            [destChainID, randomSolidityAddress_bytes, payload]
        );

        log("Initial data prepared")
        opData.initialProposal.payload = encoded_data

        const opSigners: any = [
            signers[1],
            signers[2],
            signers[3],
            signers[4],
            // signers[5],
            // signers[6],
        ];

        // log(opToSign)
        const sigs: any[] = await signConsensus(opSigners, opData);
        log(sigs)

        log("consensus created")
        let sigsFormatted = [];
        for (const sig of sigs) {
            // get v, r, s
            const oneSigFormatted = ethers.Signature.from(sig);
            sigsFormatted.push(oneSigFormatted);
        }
        log(sigsFormatted)

        const sigsEncoderF = await ethers.getContractFactory("SigsEncoderMock")
        const sigsEncoder = await sigsEncoderF.deploy()
        const packedSigs = await sigsEncoder.encode(sigs)

        const packedSigsWithLib = await sigsEncoder.encodeWithLib(sigs)
        expect(packedSigsWithLib).to.be.eq(packedSigs)
        console.log("Signing with super sig")

        const superSig = await signConsensus([signers[9]], opData)
        console.log(superSig[0])

        const sigStruct = ethers.Signature.from(superSig[0]);

        await expect(endpoint.execute(opData, [sigStruct], packedSigs)).to.emit(endpoint, "MessageExecuted")
    });

    describe("Resend / Replenish Tests", function() {      
        describe("Resend", function() {
            const testMsgHash = ethers.keccak256(ethers.toUtf8Bytes("test"));
            const value = ethers.parseEther("1");

            it("Should allow to resend", async () => {
                const MR_RESEND_COMMAND_CODE = await endpoint.MR_RESEND_COMMAND_CODE();

                await expect(endpoint.resend(testMsgHash, { value: value }))
                    .to.emit(endpoint, "MessageProposed");
            });

            it("Should revert with ZeroValue if no value send", async () => {
                await expect(endpoint.resend(testMsgHash))
                    .to.be.revertedWithCustomError(endpoint, "Endpoint__ZeroValue");
            });

            it("Should revert with InvalidHash if the function called with the incorrect message hash", async () => {
                await expect(endpoint.resend(ethers.ZeroHash, { value: value }))
                    .to.be.revertedWithCustomError(endpoint, "Endpoint__InvalidHash");
            });          
        });

        describe("Replenish", function() {
            const testMsgHash = ethers.keccak256(ethers.toUtf8Bytes("test"));
            const fee = ethers.parseEther("0.1");
            const amount = ethers.parseEther("0.5");
            const totalValue = fee + amount;
        
            it("Should allow to replenish", async () => {
                await expect(endpoint.replenish(fee, amount, testMsgHash, { value: totalValue }))
                    .to.emit(endpoint, "MessageProposed");
            });
        
            it("Should revert with InvalidValue if the value is incorrect ", async () => {
                const invalidValue = totalValue - (1n);
                await expect(endpoint.replenish(fee, amount, testMsgHash, { value: invalidValue }))
                    .to.be.revertedWithCustomError(endpoint, "Endpoint__InvalidValue");
            });
        
            it("Should revert with ZeroValue if no value send", async () => {
                await expect(endpoint.replenish(fee, amount, testMsgHash, { value: 0 }))
                    .to.be.revertedWithCustomError(endpoint, "Endpoint__ZeroValue");
            });
        
            it("Should revert with InvalidHash if the function called woth the incorrect message hash", async () => {
                await expect(endpoint.replenish(fee, amount, ethers.ZeroHash, { value: totalValue }))
                    .to.be.revertedWithCustomError(endpoint, "Endpoint__InvalidHash");
            });
        });
    });

    describe("MessageRepeater + Master", function() {
        let repeater: MessageRepeater;
        let master: Master;
        let chainInfo: ChainInfo;
        let messageData: MessageData;
        let executorLottery: ExecutorLottery;

        const srcChainId = 1;

        let setterAddr: string;

        describe("Resend", function() {
            const testHash = ethers.keccak256(ethers.toUtf8Bytes("test"));

            before(async () => {
                const adminAddr = signers[0].address;
                setterAddr = signers[1].address;
    
                repeater = await deployMessageRepeater();
                const MasterFactory = await ethers.getContractFactory("Master");
                const MessageDataFactory = await ethers.getContractFactory("MessageData");
                const args = [adminAddr, repeater.target];
    
                master = await upgrades.deployProxy(MasterFactory, [args], {
                    kind: "uups",
                    initializer: "initialize"
                });
    
                messageData = await upgrades.deployProxy(MessageDataFactory, [[adminAddr, master.target]], {
                    kind: "uups",
                    initializer: "initialize"
                });
                await messageData.waitForDeployment();
    
                const LotteryFactory = await ethers.getContractFactory("ExecutorLottery");
                executorLottery = await upgrades.deployProxy(LotteryFactory, [[adminAddr, master.target]], {
                    kind: "uups",
                    initializer: "initialize"
                });
                await executorLottery.waitForDeployment();
    
                await master.setContracts([
                    adminAddr,
                    adminAddr,
                    adminAddr,
                    messageData.target,
                    executorLottery.target,
                    adminAddr,
                    adminAddr,
                    adminAddr,
                    adminAddr
                ])
    
                const ChainInfoFactory = await ethers.getContractFactory("ChainInfo");
                chainInfo = (await upgrades.deployProxy(ChainInfoFactory, [
                    [adminAddr, setterAddr, setterAddr, setterAddr]
                ], {
                    kind: "uups",
                    initializer: "initialize" 
                }));
                await chainInfo.waitForDeployment();
    
                await chainInfo.setChainInfo(
                    srcChainId,
                    "0x0000000000000000000000000000000000000001",
                    ethers.ZeroHash,
                    18,
                    "Ethereum",
                    "ETH",
                    "https://rpc.com",
                    ethers.AbiCoder.defaultAbiCoder().encode(["address"], [endpoint.target]),
                    ethers.ZeroHash,
                    ethers.ZeroHash
                )
    
                await repeater.setMaster(master.target);
                await repeater.setChainInfo(chainInfo.target);
            });
    
            it("should successfully resend message", async () => {
                const data = ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "bytes32", "bytes", "bytes"],
                    [
                        srcChainId,
                        coder.encode(["uint256"], [1234]),
                        coder.encode(["address"], [endpoint.target]),
                        coder.encode(["bytes32"], [testHash])
                    ]
                );
                const status = await messageData.getMsgStatusByHash(testHash);
                console.log(status)

                // adjust status to not revert
                await messageData.grantRole(await messageData.PRESERVER(), owner.address)
                await messageData.changeMessageStatus(testHash, 4) // queued

                await repeater.resend(data);
          
                const executionData = await master.msgExecutionData(testHash);
                expect(executionData.resendAttempts).to.equal(1);
            });
    
            it("should reject invalid origin", async () => {
                const invalidData = ethers.AbiCoder.defaultAbiCoder().encode(
                    ["uint256", "bytes32", "bytes", "bytes"],
                    [
                        srcChainId,
                        coder.encode(["uint256"], [1234]),
                        coder.encode(["address"], [setterAddr]), 
                        coder.encode(["bytes32"], [testHash])
                    ]
                );
          
                await expect(repeater.resend(invalidData))
                    .to.be.revertedWithCustomError(repeater, "MR__InvalidOrigin");
            });    
        });

        describe("Replenish", function() {
            const testHash = ethers.keccak256(ethers.toUtf8Bytes("test2"));

            before(async () => {
                await messageData.grantRole(await messageData.PRESERVER(), owner.address);
            });
            
            it("should successfully replenish message", async () => {
                const opData = await getTestMsg();
                await messageData.storeMessage(testHash, opData);
                await messageData.changeMessageStatus(testHash, 4);

                const replenishValue = ethers.parseEther("0.5");
                const data = coder.encode(
                    ["uint256", "bytes32", "bytes", "bytes"],
                    [
                        srcChainId,
                        coder.encode(["uint256"], [1234]),
                        coder.encode(["address"], [endpoint.target]), 
                        coder.encode(["bytes32", "uint256"], [testHash, replenishValue])
                    ]
                );
          
                await expect(repeater.replenish(data))
                    .to.emit(master, "ResendMessage")
                    .withArgs(testHash);
          
                const executionData = await master.msgExecutionData(testHash);
                expect(executionData.resendAttempts).to.equal(1);
            });

            it("should reject invalid status for replenish", async () => {
                await messageData.changeMessageStatus(testHash, 1);
                
                const data = coder.encode(
                    ["uint256", "bytes32", "bytes", "bytes"],
                    [
                        srcChainId, 
                        coder.encode(["uint256"], [1234]), 
                        coder.encode(["address"], [endpoint.target]), 
                        coder.encode(["bytes32", "uint256"], [testHash, ethers.parseEther("0.5")])
                    ]
                );
          
                await expect(repeater.replenish(data))
                    .to.be.revertedWithCustomError(master, "InvalidReplenish");
            });
        });
    });
});
