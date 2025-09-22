import { HardhatUserConfig, task } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import "hardhat-contract-sizer";
import "@matterlabs/hardhat-zksync";
import "@matterlabs/hardhat-zksync-upgradable";
// import "hardhat-docgen"
import dotenv from "dotenv";
dotenv.config();

import "./tasks/index"

const config: HardhatUserConfig = {
    zksolc: {
        version: "latest",
        settings: {
          enableEraVMExtensions: true,
          suppressedErrors: ["sendtransfer"],
          suppressedWarnings: ["assemblycreate"],
        },
    },
    solidity: {
        compilers: [
            {
                version: "0.8.24",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                    viaIR: true,
                },
            },
        ],
    },
    contractSizer: {
        runOnCompile: false
    },
    // docgen: {
    //     path: './docs',
    //     clear: true,
    //     runOnCompile: false,
    // }
    // defaultNetwork: "abstract_mainnet",
    networks: {
        hardhat: {
            // @ts-ignore
            urlParsed: "http://localhost:8545",
            chainId: 31337,
            accounts: {
                count: 20
            }
        },
        localhost: {
            // @ts-ignore
            urlParsed: "http://localhost:8545",
            chainId: 31337
        },
        opbnb: {
            url: process.env.OPBNB_MAINNET || "",
            accounts: {
                mnemonic: process.env.MAINNET_MNEMONIC || "",
            },
            chainId: 204
        },
        opbnb_testnet: {
            url: process.env.OPBNB_TESTNET || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 5611
        },
        ethereum_sepolia: {
            url: process.env.ETHEREUM_SEPOLIA || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 11155111
        },
        polygon_amoy: {
            url: process.env.POLYGON_AMOY || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 80002
        },
        mantle_sepolia: {
            url: process.env.MANTLE_SEPOLIA || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 5003
        },
        base_sepolia: {
            url: process.env.BASE_SEPOLIA || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 84532
        },
        sonic_blaze: {
            url: process.env.SONIC_BLAZE || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 57054
        },
        avalanche_fuji: {
            url: process.env.AVALANCHE_FUJI || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 43113
        },
        genome_l2: {
            url: process.env.GENOME_TESTNET || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 491149
        },
        bnb_testnet: {
            url: process.env.BNB_TESTNET || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 97
        },
        arbitrum_testnet: {
            url: process.env.ARBITRUM_TESTNET || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 421614
        },
        immutable_testnet: {
            url: process.env.IMMUTABLE_TESTNET || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 13473
        },
        skale_nebula_testnet: {
            url: process.env.SKALE_NEBULA_TESTNET_URL || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 37084624
        },
        ronin_testnet: {
            url: process.env.RONIN_SAIGON_TESTNET || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 2021
        },
        sonic: {
            url: process.env.SONIC || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 146
        },
        ethereum_mainnet: {
            url: process.env.ETHEREUM_MAINNET || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 1
        },
        avalanche_mainnet: {
            url: process.env.AVALANCHE_MAINNET || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 43114
        },
        manta_pacific: {
            url: process.env.MANTA_PACIFIC || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 169
        },
        polygon_mainnet: {
            url: process.env.POLYGON_MAINNET || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 137
        },
        abstract_mainnet: {
            url: process.env.ABSTRACT_MAINNET,
            ethNetwork: "mainnet",
            zksync: true,
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 2741
        },
        berachain: {
            url: process.env.BERACHAIN_MAINNET || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 80094
        },
        mantle_mainnet: {
            url: process.env.MANTLE_MAINNET || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 5000
        },
        bsc: {
            url: process.env.BNB_MAINNET || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 56
        },
        immutable: {
            url: process.env.IMMUTABLE || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 13371
        },
        arbitrum: {
            url: process.env.ARBITRUM || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 42161
        },
        optimism: {
            url: process.env.OPTIMISM || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 10
        },
        base: {
            url: process.env.BASE || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 8453
        },
        blast: {
            url: process.env.BLAST || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 81457
        },
        ronin: {
            url: process.env.RONIN || "",
            accounts: {
                mnemonic: process.env.MAINNET_ENPOINTS_DEPLOY_MNEMONIC || "",
            },
            chainId: 2020
        },
        genome_testnet: {
            url: process.env.GENOME_L2_URL || "",
            accounts: {
                mnemonic: process.env.NEW_MNEMONIC || "",
            },
            chainId: 491149
        }
        
    },
    etherscan: {
        apiKey: {
           sepolia: process.env.ETHERSCAN_API || "",
           polygonAmoy: process.env.POLYGON_API || ""
        },
    }
};

export default config;
