// EIP-1193 + EIP-6963 wallet stub — injected into every page via CDP.
// Backed by local signer at http://127.0.0.1:8555/sign
(function () {
  if (window.__stubInjected) return;
  window.__stubInjected = true;

  const SIGNER = "http://127.0.0.1:8555/sign";
  const ADDR = "__SIGNER_ADDR__"; // replaced at inject time
  const CHAIN = "0x1237"; // 4663

  const listeners = {};

  async function signReq(method, params) {
    const r = await fetch(SIGNER, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ method, params, id: 1 }),
    });
    const j = await r.json();
    if (j.error) {
      const e = new Error(j.error.message || "signer error");
      e.code = j.error.code || -32000;
      throw e;
    }
    return j.result;
  }

  const provider = {
    isMetaMask: true,
    isRainbow: true, // Rainbow entry uses upe({flag:'isRainbow'}) -> injected connector
    selectedAddress: ADDR,
    chainId: CHAIN,
    networkVersion: "4663",
    isConnected: () => false,
    emit: (ev, ...args) => {
      (listeners[ev] || []).forEach((f) => f(...args));
      return true;
    },

    async request({ method, params = [] }) {
      console.log("[stub.req]", method, JSON.stringify(params).slice(0, 120));
      switch (method) {
        case "eth_requestAccounts":
        case "eth_accounts":
          return [ADDR];
        case "wallet_requestPermissions":
          return [{ eth_accounts: {} }];
        case "eth_chainId":
          return CHAIN;
        case "net_version":
          return "4663";
        case "wallet_switchEthereumChain":
        case "wallet_addEthereumChain":
          return null;
        case "personal_sign":
        case "eth_sign":
          return await signReq("personal_sign", params);
        case "eth_signTypedData":
        case "eth_signTypedData_v3":
        case "eth_signTypedData_v4":
          return await signReq("eth_signTypedData_v4", params);
        default:
          throw { code: -32601, message: "stub: unsupported " + method };
      }
    },

    on(ev, fn) {
      (listeners[ev] = listeners[ev] || []).push(fn);
      if (ev === "accountsChanged" || ev === "chainChanged") return () => {};
      return () => {};
    },
    removeListener(ev, fn) {
      if (listeners[ev]) listeners[ev] = listeners[ev].filter((f) => f !== fn);
    },
    removeAllListeners() {},
  };

  Object.defineProperty(window, "ethereum", {
    value: provider,
    writable: false,
    configurable: false,
  });
  // Real injected wallets expose a `.providers` array — some detectors scan it
  try { provider.providers = [provider]; } catch (e) {}

  // EIP-6963 announcement
  const info = Object.freeze({
    uuid: "9f8e7d6c-5b4a-4e3d-8c2b-1a9f0e8d7c6b",
    name: "Stub Wallet",
    icon: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='32' height='32'%3E%3Crect width='32' height='32' fill='%23333'/%3E%3C/svg%3E",
    rdns: "io.metamask",
  });
  const announce = () =>
    window.dispatchEvent(
      new CustomEvent("eip6963:announceProvider", {
        detail: Object.freeze({ info, provider }),
      })
    );
  window.addEventListener("eip6963:requestProvider", announce);
  announce();
  // Re-announce on an interval — app boot listeners often attach AFTER our
  // initial announce fires (addScriptToEvaluateOnNewDocument runs pre-app-JS).
  let n = 0;
  const iv = setInterval(() => {
    announce();
    if (++n > 60) clearInterval(iv); // stop after ~18s
  }, 300);
})();
