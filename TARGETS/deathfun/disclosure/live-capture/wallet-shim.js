/**
 * EIP-1193 wallet shim backed by the throwaway test key.
 *
 * Injected into the page BEFORE any app script runs, so the app sees a normal injected
 * wallet (window.ethereum) — MetaMask-shaped — and its SIWE / connect-wallet path works
 * unchanged. Signing is delegated to the Node side (see capture.js -> page.exposeFunction)
 * so no key material ever enters the page or the browser profile.
 *
 * Every provider call is logged to window.__walletLog so the capture records what the app
 * asked the wallet to sign — which is itself evidence about what the client expects to hold.
 */
(function () {
  const CHAIN_ID_HEX = "0xab5"; // 2741 = Abstract
  const pending = [];

  function log(entry) {
    try { (window.__walletLog = window.__walletLog || []).push(entry); } catch (e) {}
  }

  function emit(event, payload) {
    try {
      (window.__walletEvents = window.__walletEvents || {})[event] = payload;
    } catch (e) {}
  }

  const provider = {
    isMetaMask: true,
    _metamask: { isUnlocked: async () => true },
    chainId: CHAIN_ID_HEX,
    networkVersion: "2741",
    selectedAddress: null,

    isConnected: () => true,
    enable: async () => provider.request({ method: "eth_requestAccounts" }),

    async request({ method, params = [] }) {
      log({ dir: "wallet<-app", method, params: summarise(params) });
      let result;
      switch (method) {
        case "eth_chainId":
          result = CHAIN_ID_HEX; break;
        case "net_version":
          result = "2741"; break;
        case "eth_accounts":
        case "eth_requestAccounts":
          result = await window.__nodeCall("accounts");
          provider.selectedAddress = result[0];
          break;
        case "wallet_requestPermissions":
        case "wallet_getPermissions":
          result = [{ parentCapability: "eth_accounts" }]; break;
        case "wallet_switchEthereumChain":
        case "wallet_addEthereumChain":
        case "wallet_watchAsset":
          result = null; break;
        case "personal_sign":
          result = await window.__nodeCall("personal_sign", params); break;
        case "eth_sign":
          result = await window.__nodeCall("eth_sign", params); break;
        case "eth_signTypedData":
        case "eth_signTypedData_v3":
        case "eth_signTypedData_v4":
          result = await window.__nodeCall("signTypedData", params); break;
        case "eth_sendTransaction":
          result = await window.__nodeCall("sendTransaction", params); break;
        case "eth_sendRawTransaction":
          result = await window.__nodeCall("rpc", { method, params }); break;
        case "eth_estimateGas":
        case "eth_call":
        case "eth_getBalance":
        case "eth_getTransactionCount":
        case "eth_getBlockByNumber":
        case "eth_gasPrice":
        case "eth_maxPriorityFeePerGas":
        case "eth_feeHistory":
        case "eth_getCode":
        case "eth_getLogs":
        case "eth_blockNumber":
        case "eth_getTransactionReceipt":
          result = await window.__nodeCall("rpc", { method, params }); break;
        default:
          log({ dir: "wallet", method, note: "unhandled -> null" });
          result = null;
      }
      log({ dir: "wallet->app", method, result: summarise([result]) });
      return result;
    },
  };

  function summarise(v) {
    return JSON.parse(JSON.stringify(v, (k, val) => {
      if (typeof val === "string" && val.length > 300) return val.slice(0, 300) + `…[${val.length}]`;
      if (typeof val === "bigint") return val.toString();
      return val;
    }));
  }

  // announce like a real injected wallet
  let announce = () => emit("chainChanged", CHAIN_ID_HEX);
  announce();
  emit("accountsChanged", []);

  try {
    Object.defineProperty(window, "ethereum", {
      value: provider, writable: false, configurable: true,
    });
  } catch (e) {
    window.ethereum = provider;
  }
  // some apps look for these EIP-6963 / multi-provider hints before falling back to window.ethereum
  window.__walletReady = true;
  window.dispatchEvent(new Event("ethereum#initialized"));
  log({ dir: "shim", note: "installed", chainId: CHAIN_ID_HEX });
})();
