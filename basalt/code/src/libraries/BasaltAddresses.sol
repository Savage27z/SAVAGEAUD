// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library BasaltAddresses {

    // ── GMX Synthetics ──

    // https://arbiscan.io/address/0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8
    address internal constant GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    // https://arbiscan.io/address/0x47c031236e19d024b42f8AE6780E44A573170703
    address internal constant GM_MARKET_TOKEN = 0x47c031236e19d024b42f8AE6780E44A573170703;

    // ExchangeRouter v2.2 (ROUTER_PLUGIN-authorized).
    // https://arbiscan.io/address/0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41
    address internal constant GMX_EXCHANGE_ROUTER = 0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41;
    // GMX v2 Router — sendTokens approvals.
    // https://arbiscan.io/address/0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6
    address internal constant GMX_V2_ROUTER = 0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6;
    // DepositVault — sendWnt/sendTokens target on createDeposit.
    // https://arbiscan.io/address/0xF89e77e8Dc11691C9e8757e84aaFbCD8A67d7A55
    address internal constant GMX_DEPOSIT_VAULT = 0xF89e77e8Dc11691C9e8757e84aaFbCD8A67d7A55;
    // DepositHandler — authed caller for afterDeposit* callbacks.
    // https://arbiscan.io/address/0x33871b8568eDC4adf33338cdD8cF52a0eCC84D42
    address internal constant GMX_DEPOSIT_HANDLER = 0x33871b8568eDC4adf33338cdD8cF52a0eCC84D42;
    // WithdrawalVault — sendWnt/sendTokens target on createWithdrawal.
    // https://arbiscan.io/address/0x0628D46b5D145f183AdB6Ef1f2c97eD1C4701C55
    address internal constant GMX_WITHDRAWAL_VAULT = 0x0628D46b5D145f183AdB6Ef1f2c97eD1C4701C55;
    // WithdrawalHandler — authed caller for afterWithdrawal* callbacks.
    // https://arbiscan.io/address/0x11e9E7464f3Bc887a7290ec41fCd22f619b177fd
    address internal constant GMX_WITHDRAWAL_HANDLER = 0x11e9E7464f3Bc887a7290ec41fCd22f619b177fd;

    // ── Tokens ──

    // https://arbiscan.io/address/0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f
    address internal constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    // https://arbiscan.io/address/0xaf88d065e77c8cC2239327C5EDb3A432268e5831
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    // ── Dolomite ──

    // https://arbiscan.io/address/0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072
    address internal constant DOLOMITE_MARGIN = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;
    // GmxV2IsolationModeVaultFactory for GM WBTC/USDC.
    // https://arbiscan.io/address/0x1E8e8B7a2F827b3bc12B00eE402145061b7050eF
    address internal constant VAULT_FACTORY = 0x1E8e8B7a2F827b3bc12B00eE402145061b7050eF;
    // Dolomite GMX v2 wrapper/unwrapper registry.
    // https://arbiscan.io/address/0xaDC1A8AD79E55Ab9E8569e497775B63e737316A8
    address internal constant GMX_V2_REGISTRY = 0xaDC1A8AD79E55Ab9E8569e497775B63e737316A8;

    // ── Chainlink Oracles ──

    // https://arbiscan.io/address/0xd0C7101eACbB49F3deCcCc166d238410D6D46d57
    // https://data.chain.link/feeds/arbitrum/mainnet/wbtc-usd
    address internal constant CL_WBTC_USD = 0xd0C7101eACbB49F3deCcCc166d238410D6D46d57;
    // https://arbiscan.io/address/0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3
    // https://data.chain.link/feeds/arbitrum/mainnet/usdc-usd
    address internal constant CL_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    // https://arbiscan.io/address/0xFdB631F5EE196F0ed6FAa767959853A9F217697D
    // https://docs.chain.link/data-feeds/l2-sequencer-feeds#arbitrum
    address internal constant CL_SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // ── WETH ──

    // https://arbiscan.io/address/0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // ── Uniswap V3 (emergency swap module) ──

    // SwapRouter02.
    // https://arbiscan.io/address/0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
    address internal constant UNI_V3_SWAP_ROUTER =
        0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    // WBTC/USDC 0.05% pool.
    // https://arbiscan.io/address/0x0E4831319A50228B9e450861297aB92dee15B44F
    address internal constant UNI_V3_POOL_WBTC_USDC =
        0x0E4831319A50228B9e450861297aB92dee15B44F;

    // WETH/USDC 0.05% pool.
    // https://arbiscan.io/address/0xC6962004f452bE9203591991D15f6b388e09E8D0
    address internal constant UNI_V3_POOL_WETH_USDC =
        0xC6962004f452bE9203591991D15f6b388e09E8D0;
}
