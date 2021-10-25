I just lost a few hours progress thanks to trusting Remix IDE to store my stuff I will do frequent commits to make sure I don't go around losing history again. Thankfully not much was lost. I remember most of the changes and I've kept track of the important stuff with my notes.

This repo is intended for archival, not usage of any kind! Contract may be filled with unprofessional notes. Will attempt to get the "proper" solidity comment style later, but for now I just want to get it done.

# Slot Curate
A complete overhaul of Curate to make it as gas efficient as theoretically possible (theoretically possible means, I haven't come up with a better way.) Main innovation is standarizing "slots" to be rewritten later, because writing storage in used slots is way cheaper. Instead of keeping around trash data, reuse that space for cheaper usage.

Most of the work will be done by the subgraph. And it is very difficult to do this without changing much of the interfaces. Kleros Arbitrable standards will be kept (and attempt will be made) But main priority is keeping mainline use cases extremely cheap


-------------------

# Advanced Sample Hardhat Project

This project demonstrates an advanced Hardhat use case, integrating other tools commonly used alongside Hardhat in the ecosystem.

The project comes with a sample contract, a test for that contract, a sample script that deploys that contract, and an example of a task implementation, which simply lists the available accounts. It also comes with a variety of other tools, preconfigured to work with the project code.

Try running some of the following tasks:

```shell
npx hardhat accounts
npx hardhat compile
npx hardhat clean
npx hardhat test
npx hardhat node
npx hardhat help
REPORT_GAS=true npx hardhat test
npx hardhat coverage
npx hardhat run scripts/deploy.js
node scripts/deploy.js
npx eslint '**/*.js'
npx eslint '**/*.js' --fix
npx prettier '**/*.{json,sol,md}' --check
npx prettier '**/*.{json,sol,md}' --write
npx solhint 'contracts/**/*.sol'
npx solhint 'contracts/**/*.sol' --fix
```

# Etherscan verification

To try out Etherscan verification, you first need to deploy a contract to an Ethereum network that's supported by Etherscan, such as Ropsten.

In this project, copy the .env.example file to a file named .env, and then edit it to fill in the details. Enter your Etherscan API key, your Ropsten node URL (eg from Alchemy), and the private key of the account which will send the deployment transaction. With a valid .env file in place, first deploy your contract:

```shell
hardhat run --network ropsten scripts/deploy.js
```

Then, copy the deployment address and paste it in to replace `DEPLOYED_CONTRACT_ADDRESS` in this command:

```shell
npx hardhat verify --network ropsten DEPLOYED_CONTRACT_ADDRESS "Hello, Hardhat!"
```
