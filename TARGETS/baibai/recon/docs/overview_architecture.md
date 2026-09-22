> ## Documentation Index
> Fetch the complete documentation index at: https://docs.baibai.cx/llms.txt
> Use this file to discover all available pages before exploring further.

# Architecture

> BaiBai combines PropAMMs with a synchronously composable appchain to deliver the best execution in the EVM ecosystem.

<img src="https://mintcdn.com/bai-bai/Cc4kKwp4X4siOF4j/images/baibai_architecture.png?fit=max&auto=format&n=Cc4kKwp4X4siOF4j&q=85&s=a0cf4a47a2bad11d441612a9361898da" alt="BaiBai architecture diagram" width="1920" height="1080" data-path="images/baibai_architecture.png" />

BaiBai is built on **Pylon**, an appchain framework that provides dedicated blockspace while remaining synchronously composable with the underlying settlement chain.

The BaiBai appchain handles market-maker updates and execution logic. Through synchronous composability, users and applications interact using their normal Base balances without bridging assets or managing a separate network.

For wallets, aggregators, and other integrations, BaiBai is accessed through the BaiBai API. The appchain remains entirely behind the scenes.

## Liquidity

**BaiBai aggregates active and passive liquidity into a single execution venue.**

Liquidity comes from BaiBai PropAMMs and other integrated liquidity sources. Each PropAMM operates independently and continuously updates its own pricing, inventory, and risk model.

The routing engine compares every available source and selects the one offering the best execution after accounting for fees and gas.

## More than a PropAMM

Unlike a standalone PropAMM, BaiBai combines PropAMMs and intelligent routing. Every order is routed to the liquidity source that offers the best available execution, allowing users to benefit from both active professional liquidity and existing onchain liquidity through a single interface.
