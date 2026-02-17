<div align="center">


  <h1>ACP</h1>

  <p>
    <strong>Agent Communication Protocol</strong>
  </p>
</div>

ACP is an omnichain framework designed
to establish seamless and secure communication between diverse blockchain 
networks, including both EVM and non-EVM chains. Actra enables developers to 
build decentralized applications that can send data, transfer assets,
and perform custom operations across multiple chains without needing 
complex cross-chain solutions.

## Table of Contents

- [Core Concepts](#core-concepts)
- [Components](#components)
    - [Off-Chain Components](#off-chain-components)
    - [On-Chain Components](#on-chain-components)
- [Building the project](#build-and-install)
    - [Compilation](#compiling-the-contracts)
- [Testing](#testing)
    - [Local Testing](#local-testing)
    - [Testnet/Mainnet Testing](#testnetmainnet-testing)
- [Integration](#integration)
- [Audits](#audits)
- [License](#license)

## Core Concepts

Before diving into implementation, it's important to understand these key concepts:

- **Agent Communication Protocol:** The omnichain protocol that 
handles message routing, processing and validation across different blockchains.
- **Protocol:** A third-party system built on top of ACP. This could be
an application, a dapp, or any other system.
- **Message:** An abstract piece of data passed between chains via ACP.  
Messages can contain transaction data, parameters for smart contract calls, 
or any other type of information necessary for cross-chain or omnichain 
functionality.


## Components

Agent Communication Protocol operates with both off-chain and on-chain components:

### Off-Chain Components
These are responsible for relaying messages and ensuring the overall 
operation of the network.

- **Agent Network:** A Delegated Proof of Stake (DPoS) network composed of 
off-chain machines known as *Agents*.  
This network is responsible for transmitting and validating cross-chain 
communication.
- **Agent:** A machine within the Agent Network that participates in 
message processing. Agents validate transactions, submit them to the target 
chains, and maintain the network.
- **Super-agent:**  A specialized Agent within the Agent Network that focuses 
specifically on validating actions performed by other Agents. 
This provides an added layer of security.
- **Executor:**  A module within the Agent, responsible for executing 
transactions on target chains.
- **Listener:** A module within the Agent that identifies and retrieves 
proposals for message transmission from source chains.
- **Transmitter:**  A module within the Agent, responsible for posting proposals 
into the on-chain system of opBNB smart contracts.
- **DF Adapter:** A utility within the Agent, that calculates transaction fees, 
cross-chain estimations for messages, and valuation of native currencies.

### On-Chain Components
These are smart contracts that handle the protocol logic on individual blockchains.

- **Endpoint:** The main smart contract which receives and handles messages, 
acting as the entry point to the *Protocol* on a given blockchain.
- **Protocol Contract:**  A smart contract that implements a specific function 
or feature and is called by the Endpoint when processing a message.
- **Proposer Contract:**  A contract that creates messages for processing and 
delivery by the Agent Communication Protocol.
- **opBNB Contracts:** A comprehensive set of smart contracts facilitating core 
functions, such as staking, agent registration, consensus validation and 
message processing.

## Build and Install

### Compiling the contracts

To compile the project contracts use:
```bash
npx hardhat compile
```


## Testing

### Local testing
```bash
yarn test
```

### Testnet or mainnet testing
Please refer to [integration](#integration) section.


## License

MIT