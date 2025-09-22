import {
    HardhatEthersSigner,
    SignerWithAddress,
} from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { BytesLike } from "ethers";
import { ethers } from "hardhat";
import { MessageLib } from "../typechain-types/contracts/EndPoint";
import { TransmitterParamsLib } from "../typechain-types/contracts/lib";
import { log } from "./testLogger";
import { TEST_DEST_CHAIN_ID } from "../utils/constants";

const coder = ethers.AbiCoder.defaultAbiCoder();

async function signConsensus(
    signers: SignerWithAddress[],
    data: any
): Promise<any> {
    const signatures: any = [];

    const hash = ethers.solidityPackedKeccak256(
        [
            "uint256",
            "uint256",
            "bytes32",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes32[2]",
        ],
        [
            data.initialProposal.destChainId,
            data.initialProposal.nativeAmount,
            data.initialProposal.selectorSlot,
            getLenBytes(data.initialProposal.senderAddr.length),
            data.initialProposal.senderAddr,
            getLenBytes(data.initialProposal.destAddr.length),
            data.initialProposal.destAddr,
            getLenBytes(data.initialProposal.payload.length),
            data.initialProposal.payload,
            getLenBytes(data.initialProposal.reserved.length),
            data.initialProposal.reserved,
            getLenBytes(data.initialProposal.transmitterParams.length),
            data.initialProposal.transmitterParams,
            data.srcChainData.location,
            data.srcChainData.srcOpTxId,
        ]
    );

    // console.log("Hash TS :", hash);

    const hashPrefixed = ethers.solidityPackedKeccak256(
        ["string", "bytes32"],
        ["\x19Ethereum Signed Message:\n32", ethers.getBytes(hash)]
    );
    // console.log("Prefixed TS:", hashPrefixed, "\n");

    // sign data with ethers
    log("=== Consensus Signatures ===");
    for (const signer of signers) {
        const hashBytes = ethers.getBytes(hash);
        const sig = await signer.signMessage(hashBytes);

        signatures.push(sig);

        const sigStruct = ethers.Signature.from(sig);
        expect(signer.address).eq(ethers.verifyMessage(hashBytes, sigStruct));

        // log them all
        const indexOfSigner = signers.indexOf(signer);
        log(indexOfSigner, ":", await signer.getAddress(), ":", sig);
    }
    log("")

    return signatures;
}

function getLenBytes(dataLen: number) {
    return (dataLen - 2) / 2
}

export const selector = "0x61605daf" // Endpoint::execute(...)
export const exCode = 1
const exCodeType = "0x01"

function encodeDefaultSelector() {
    // create new 32 byte hex string
    const bytes4 = ethers.hexlify(Buffer.from(selector.replace('0x', ''), 'hex'));
    const bytes32 = ethers.zeroPadValue(bytes4, 32);
    return bytes32
}

function encodeExecutionCode() {
    // uint256 to hex 
    const slot = coder.encode(
        ["uint256"],
        [exCode]
    )
    // replace 0x0 with 0x1
    const res = slot.replace('0x00', exCodeType);
    return res
}

async function signSolo(signer: HardhatEthersSigner, data: MessageLib.MessageDataStruct) {
    const hash = ethers.solidityPackedKeccak256(
        [
            "uint256",
            "uint256",
            "bytes32",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes32[2]",
        ],
        [
            data.initialProposal.destChainId,
            data.initialProposal.nativeAmount,
            data.initialProposal.selectorSlot,
            getLenBytes(data.initialProposal.senderAddr.length),
            data.initialProposal.senderAddr,
            getLenBytes(data.initialProposal.destAddr.length),
            data.initialProposal.destAddr,
            getLenBytes(data.initialProposal.payload.length),
            data.initialProposal.payload,
            getLenBytes(data.initialProposal.reserved.length),
            data.initialProposal.reserved,
            getLenBytes(data.initialProposal.transmitterParams.length),
            data.initialProposal.transmitterParams,
            data.srcChainData.location,
            data.srcChainData.srcOpTxId,
        ]
    );

    const hashBytes = ethers.getBytes(hash);
    const sig = await signer.signMessage(hashBytes);

    // separate sig to v,r,s
    const sigStruct = ethers.Signature.from(sig);
    
    return sigStruct
}

async function getTestMsg(
    addressTo: string = "0xF135B9eD84E0AB08fdf03A744947cb089049bd79"
) {
    const payload = coder.encode(
            ["string"],
            ["hello world"]
    )

    const transmitterParams: TransmitterParamsLib.TransmitterParamsStruct = {
        waitForBlocks: 3n,
        customGasLimit: 0n,
    };

    const proposal: MessageLib.ProposalStruct = {
        destChainId: TEST_DEST_CHAIN_ID,
        nativeAmount: 10000,
        selectorSlot: encodeDefaultSelector(),
        senderAddr: coder.encode(["address"], ["0xF135B9eD84E0AB08fdf03A744947cb089049bd79"]),
        destAddr: coder.encode(
            ["address"],
            [addressTo]
        ),
        payload: payload,
        reserved: "0x",
        transmitterParams: coder.encode(
            ["uint256", "uint256"],
            [transmitterParams.waitForBlocks, transmitterParams.customGasLimit]
        )
    };

    // test data only
    // const txIdTestPack: BytesLike = ethers.getBytes(ethers.ZeroHash);           -- conflict with master::validateSrcData()
    // const txIdTestPack: BytesLike = ethers.randomBytes(32)
    const txIdTestPack: BytesLike = coder.encode(
        ["uint256"],
        ["111"]
    )
    const srcChainData: MessageLib.SrcChainDataStruct = {
        // srcChainId: 1,
        // srcBlockNumber: 111,
        location: (1n << 128n) + 111n,
        srcOpTxId: [txIdTestPack, txIdTestPack],
    };

    const opData: MessageLib.MessageDataStruct = {
        initialProposal: proposal,
        srcChainData: srcChainData,
    };

    return opData;
}

async function getTestRawMsg(
    addressTo: string = "0xF135B9eD84E0AB08fdf03A744947cb089049bd79"
) {
    const payload = coder.encode(
            ["string"],
            ["hello world"]
    )

    const transmitterParams: TransmitterParamsLib.TransmitterParamsStruct = {
        waitForBlocks: 3,
        customGasLimit: 0,
    };

    const proposal: MessageLib.ProposalStruct = {
        destChainId: TEST_DEST_CHAIN_ID,
        nativeAmount: 10000,
        selectorSlot: encodeDefaultSelector(),
        senderAddr: coder.encode(["address"], ["0xF135B9eD84E0AB08fdf03A744947cb089049bd79"]),
        destAddr: coder.encode(
            ["address"],
            [addressTo]
        ),
        payload: payload,
        reserved: ethers.ZeroHash,
        transmitterParams: coder.encode(
            ["uint256", "uint256"],
            [transmitterParams.waitForBlocks, transmitterParams.customGasLimit]
        )
    };

    // test data only
    // const txIdTestPack: BytesLike = ethers.getBytes(ethers.ZeroHash);           -- conflict with master::validateSrcData()
    // const txIdTestPack: BytesLike = ethers.randomBytes(32)                      -- conflict with master::verifyConsensus() in master.test.ts
    const txIdTestPack: BytesLike = coder.encode(
        ["uint256"],
        ["111"]
    )
    const srcChainData: MessageLib.SrcChainDataStruct = {
        srcChainId: 1,
        srcBlockNumber: 111,
        // location: (1n << 128n) + 111n,
        srcOpTxId: [txIdTestPack, txIdTestPack],
    };

    const opData: MessageLib.MessageDataStruct = {
        initialProposal: proposal,
        srcChainData: srcChainData,
    };

    return opData;
}

async function getChainDataHash(data: MessageLib.SrcChainDataStruct) {
    return ethers.solidityPackedKeccak256(
        ["uint128", "bytes32", "bytes32"],
        [
            (BigInt(data.location) >> 128n),
            data.srcOpTxId[0],
            data.srcOpTxId[1]
        ]
    );
}

async function getPrefixedMsg(data: any) {
    const hash = ethers.solidityPackedKeccak256(
        [
            "uint256",
            "uint256",
            "bytes32",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes",
            "uint256",
            "bytes32[2]",
        ],
        [
            data.initialProposal.destChainId,
            data.initialProposal.nativeAmount,
            data.initialProposal.selectorSlot,
            getLenBytes(data.initialProposal.senderAddr.length),
            data.initialProposal.senderAddr,
            getLenBytes(data.initialProposal.destAddr.length),
            data.initialProposal.destAddr,
            getLenBytes(data.initialProposal.payload.length),
            data.initialProposal.payload,
            getLenBytes(data.initialProposal.reserved.length),
            data.initialProposal.reserved,
            getLenBytes(data.initialProposal.transmitterParams.length),
            data.initialProposal.transmitterParams,
            data.srcChainData.location,
            data.srcChainData.srcOpTxId,
        ]
    );

    const hashPrefixed = ethers.solidityPackedKeccak256(
        ["string", "bytes32"],
        ["\x19Ethereum Signed Message:\n32", ethers.getBytes(hash)]
    );
    return hashPrefixed
}

export { 
    signConsensus,
    encodeDefaultSelector,
    encodeExecutionCode,
    getTestMsg,
    getTestRawMsg,
    signSolo,
    getChainDataHash,
    getPrefixedMsg
};
