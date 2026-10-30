# Bet2Gether contracts

Foundry project for the two Bet2Gether contracts on Ethereum Sepolia:

- [`src/PredictionPool.sol`](src/PredictionPool.sol): rounds, time-weighted bets, resolution by Chainlink Automation and price feeds, pull-payment claims.
- [`src/PredictionPoolToken.sol`](src/PredictionPoolToken.sol): ERC-1155 collectible, minted through Chainlink VRF v2.5 by an address with `MINTER_ROLE`.

What they do, the known bugs and the deployed addresses are in the [root README](../README.md).

## Commands

```bash
forge install
forge build
forge test
forge coverage
```

## Deploy

Set `ALCHEMY_SEPOLIA_RPC_URL`, `PRIVATE_KEY` and `ETHERSCAN_API_KEY` in `be/.env`, then:

```bash
forge script script/PredictionPoolScript.s.sol --rpc-url $ALCHEMY_SEPOLIA_RPC_URL --broadcast --verify
forge script script/PredictionPoolTokenScript.s.sol --rpc-url $ALCHEMY_SEPOLIA_RPC_URL --broadcast --verify
```

Feeds and VRF settings are in `script/Constants_PredictionPool.sol` and `script/Constants_PredictionPoolToken.sol`.
