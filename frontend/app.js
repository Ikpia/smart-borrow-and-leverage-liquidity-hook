/* global ethers */

const CONFIG = {
  router: "0x0000000000000000000000000000000000000000",
  riskManager: "0x0000000000000000000000000000000000000000",
  liquidation: "0x0000000000000000000000000000000000000000",
  metricsHook: "0x0000000000000000000000000000000000000000"
};

const ABI = {};
let provider;
let signer;
let account;

const $ = (id) => document.getElementById(id);

const ui = {
  activity: $("activity"),
  snapshot: $("snapshot"),
  walletState: $("walletState")
};

async function loadAbi() {
  const files = [
    ["router", "/shared/abis/LeverageRouter.json"],
    ["risk", "/shared/abis/RiskManager.json"],
    ["liquidation", "/shared/abis/LiquidationModule.json"],
    ["metrics", "/shared/abis/MockMetricsHook.json"]
  ];

  for (const [name, path] of files) {
    try {
      const res = await fetch(path);
      const json = await res.json();
      ABI[name] = json.abi || json;
    } catch (err) {
      log(`ABI load warning for ${name}: ${err.message}`);
    }
  }
}

function log(message) {
  const stamp = new Date().toISOString();
  ui.activity.textContent = `[${stamp}] ${message}\n${ui.activity.textContent}`;
}

function asWei(value) {
  return ethers.parseEther(String(value || "0"));
}

async function connect() {
  if (!window.ethereum) {
    log("No injected wallet found.");
    return;
  }

  provider = new ethers.BrowserProvider(window.ethereum);
  await provider.send("eth_requestAccounts", []);
  signer = await provider.getSigner();
  account = await signer.getAddress();
  ui.walletState.textContent = account;
  log(`connected: ${account}`);
}

function routerContract() {
  return new ethers.Contract(CONFIG.router, ABI.router, signer);
}

function riskContract() {
  return new ethers.Contract(CONFIG.riskManager, ABI.risk, signer);
}

function liquidationContract() {
  return new ethers.Contract(CONFIG.liquidation, ABI.liquidation, signer);
}

function metricsContract() {
  return new ethers.Contract(CONFIG.metricsHook, ABI.metrics, signer);
}

async function openPosition() {
  try {
    const c0 = asWei($("collateral0").value);
    const c1 = asWei($("collateral1").value);
    const borrow = asWei($("borrowAmount").value);
    const liq = BigInt($("liquidityDelta").value || "0");
    const minHealth = BigInt($("minHealthOpen").value || "1000000000000000000");

    // PoolKey is intentionally left as placeholders; update with deployed values.
    const params = {
      key: {
        currency0: "0x0000000000000000000000000000000000000000",
        currency1: "0x0000000000000000000000000000000000000000",
        fee: 3000,
        tickSpacing: 60,
        hooks: "0x0000000000000000000000000000000000000000"
      },
      tickLower: -900,
      tickUpper: 900,
      baseLiquidity: 100000,
      collateral0: c0,
      collateral1: c1,
      borrowAmount: borrow,
      leveragedLiquidity: liq,
      minHealthFactorWad: minHealth
    };

    const tx = await routerContract().openBorrowAndReinvest(params);
    log(`openBorrowAndReinvest submitted: ${tx.hash}`);
    await tx.wait();
    log("openBorrowAndReinvest confirmed");
  } catch (err) {
    log(`open failed: ${err.shortMessage || err.message}`);
  }
}

async function borrowMore() {
  try {
    const id = BigInt($("positionId").value || "0");
    const amt = asWei($("borrowMore").value);
    const liq = BigInt($("liqAdd").value || "0");
    const tx = await routerContract().borrowAndReinvest(id, amt, liq, 1000000000000000000n);
    log(`borrowAndReinvest submitted: ${tx.hash}`);
    await tx.wait();
    log("borrowAndReinvest confirmed");
  } catch (err) {
    log(`borrow failed: ${err.shortMessage || err.message}`);
  }
}

async function repayAndUnwind() {
  try {
    const id = BigInt($("positionId").value || "0");
    const repay = asWei($("repayAmount").value);
    const w0 = asWei($("withdraw0").value);
    const w1 = asWei($("withdraw1").value);

    const tx = await routerContract().repayAndUnwind(id, repay, w0, w1, 0);
    log(`repayAndUnwind submitted: ${tx.hash}`);
    await tx.wait();
    log("repayAndUnwind confirmed");
  } catch (err) {
    log(`repay failed: ${err.shortMessage || err.message}`);
  }
}

async function refreshSnapshot() {
  try {
    const id = BigInt($("positionId").value || "0");
    const s = await riskContract().snapshot(id);
    ui.snapshot.textContent = JSON.stringify(
      {
        rawValueQuote: s.rawValueQuote.toString(),
        collateralValueQuote: s.collateralValueQuote.toString(),
        debtQuote: s.debtQuote.toString(),
        maxBorrowQuote: s.maxBorrowQuote.toString(),
        liquidationValueQuote: s.liquidationValueQuote.toString(),
        adjustedLtvBps: s.adjustedLtvBps,
        adjustedLiquidationLtvBps: s.adjustedLiquidationLtvBps,
        adjustedCollateralFactorBps: s.adjustedCollateralFactorBps,
        riskPenaltyBps: s.riskPenaltyBps,
        healthFactorWad: s.healthFactorWad.toString()
      },
      null,
      2
    );
    log("snapshot refreshed");
  } catch (err) {
    log(`snapshot failed: ${err.shortMessage || err.message}`);
  }
}

async function applyStress() {
  try {
    const id = BigInt($("positionId").value || "0");
    const tick = Number($("stressTick").value || "0");
    const vol = Number($("stressVol").value || "0");
    const depth = Number($("stressDepth").value || "0");

    if (!ABI.metrics) {
      log("metrics hook ABI unavailable; cannot apply stress");
      return;
    }

    const poolIdHex = ethers.zeroPadValue(ethers.toBeHex(id), 32);
    const tx = await metricsContract().setPoolMetrics(poolIdHex, tick, vol, depth);
    log(`stress tx submitted: ${tx.hash}`);
    await tx.wait();
    log("stress applied (mock hook)");
  } catch (err) {
    log(`stress failed: ${err.shortMessage || err.message}`);
  }
}

async function liquidate() {
  try {
    const id = BigInt($("positionId").value || "0");
    const repay = asWei($("liqRepay").value);

    const tx = await liquidationContract().liquidate(id, repay, 0, 0);
    log(`liquidate submitted: ${tx.hash}`);
    await tx.wait();
    log("liquidation confirmed");
  } catch (err) {
    log(`liquidation failed: ${err.shortMessage || err.message}`);
  }
}

function wire() {
  $("connectBtn").addEventListener("click", connect);
  $("openBtn").addEventListener("click", openPosition);
  $("borrowBtn").addEventListener("click", borrowMore);
  $("repayBtn").addEventListener("click", repayAndUnwind);
  $("refreshBtn").addEventListener("click", refreshSnapshot);
  $("stressBtn").addEventListener("click", applyStress);
  $("liquidateBtn").addEventListener("click", liquidate);
}

(async function init() {
  await loadAbi();
  wire();
  log("console ready; set addresses in frontend/app.js CONFIG.");
})();
