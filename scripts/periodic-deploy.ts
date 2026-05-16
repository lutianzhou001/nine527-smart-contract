/**
 * periodic-deploy.ts
 *
 * Deploys nine527 meme tokens on X Layer mainnet at random intervals.
 * Token names are sourced from live news headlines (English + Chinese RSS).
 * Mines CREATE2 vanity salts locally (no RPC calls needed for mining).
 *
 * Usage:
 *   PRIVATE_KEY=0x... npx ts-node --project tsconfig.json scripts/periodic-deploy.ts
 *   or: add PRIVATE_KEY to .env then run the same command
 *
 * Dry-run (estimate costs, no transactions):
 *   PRIVATE_KEY=0x... DRY_RUN=true npx ts-node --project tsconfig.json scripts/periodic-deploy.ts
 *
 * Optional env vars:
 *   DRY_RUN=true        — estimate costs but do not send transactions
 *   START_DELAY_MIN=0   — wait N minutes before the first deployment
 */

import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import * as https from "https";
import * as http from "http";
import { URL } from "url";

// ─── dotenv (graceful: works even if no .env file) ───────────────────────────
try {
  require("dotenv").config();
} catch {
  // dotenv not installed; rely on shell env vars
}

// ═══════════════════════════════════════════════════════════════════════════════
// CONFIGURATION  ← edit this section to customise behaviour
// ═══════════════════════════════════════════════════════════════════════════════
const CONFIG = {
  // ── Network ────────────────────────────────────────────────────────────────
  rpcUrl:         "https://rpc.xlayer.tech",
  chainId:        196,
  factoryAddress: "0x5AeA8C284a3e162C04e926fa8Db69d726754f1Fd",

  // ── Randomised deployment window ──────────────────────────────────────────
  // Interval between each launch is drawn uniformly from [min, max] minutes.
  minIntervalMinutes: 1,
  maxIntervalMinutes: 1,

  // ── Optional startup delay (override via START_DELAY_MIN env var) ─────────
  startDelayMinutes: Number(process.env.START_DELAY_MIN ?? 0),

  // ── Treasury fee for every token deployed (0–300 BP = 0–3%) ──────────────
  treasuryFeeBP: 100,  // 1%

  // ── Maximum salt-mining iterations before giving up on a vanity address ───
  maxMiningIterations: 20_000_000,

  // ── Log file (appended on every deployment) ───────────────────────────────
  logFile: path.join(process.cwd(), "logs", "deployments.jsonl"),

  // ── How often to refresh the news-based token pool ────────────────────────
  newsRefreshIntervalMs: 60 * 60 * 1000, // 1 hour
} as const;

// ─── Chinese meme token pool (randomly mixed into every deployment cycle) ────
const CHINESE_MEME_POOL = [
  // People & personalities
  { name: "欧易人生",     symbol: "OKX9K"  },
  { name: "币安人生",     symbol: "BNB9K"  },
  { name: "马斯克",       symbol: "MUSK9K" },
  { name: "罗永浩",       symbol: "LYH9K"  },
  { name: "中本聪",       symbol: "SATO9K" },
  { name: "韭菜",         symbol: "LEEK9K" },
  { name: "孙宇晨",       symbol: "SUN9K"  },
  { name: "赵长鹏",       symbol: "CZ9527" },
  { name: "比特大陆",     symbol: "BITMN"  },
  { name: "吴忌寒",       symbol: "WJH9K"  },
  { name: "李启威",       symbol: "LQW9K"  },
  { name: "李笑来",       symbol: "LXL9K"  },
  { name: "老韭菜",       symbol: "OLEEK"  },
  { name: "币圈大佬",     symbol: "BOSS9K" },
  { name: "矿工老王",     symbol: "MINER"  },
  // Market sentiment
  { name: "牛市来了",     symbol: "BULL9K" },
  { name: "暴富密码",     symbol: "RICH9K" },
  { name: "到月球",       symbol: "MOON9K" },
  { name: "躺平",         symbol: "TANG9K" },
  { name: "梭哈",         symbol: "SUOHA"  },
  { name: "抄底",         symbol: "DIP9K"  },
  { name: "逃顶",         symbol: "TOP9K"  },
  { name: "割肉",         symbol: "CUT9K"  },
  { name: "爆仓",         symbol: "LIQ9K"  },
  { name: "清仓跑路",     symbol: "RUG9K"  },
  { name: "百倍币",       symbol: "100X9K" },
  { name: "千倍暴涨",     symbol: "1000X"  },
  { name: "熊市末日",     symbol: "BEAR9K" },
  { name: "牛转熊",       symbol: "FLIP9K" },
  { name: "永不下车",     symbol: "HODL9K" },
  { name: "全仓冲",       symbol: "ALL9K"  },
  { name: "涨停",         symbol: "LIMIT"  },
  { name: "跌停",         symbol: "LDOWN"  },
  { name: "绿了",         symbol: "GREEN"  },
  { name: "红了",         symbol: "RED9K"  },
  // Ecosystem & tech
  { name: "元宇宙",       symbol: "META9K" },
  { name: "加密春天",     symbol: "CRYP9K" },
  { name: "东方神秘",     symbol: "EAST9K" },
  { name: "比特黄金",     symbol: "BTCG9K" },
  { name: "以太坊梦",     symbol: "ETHDM"  },
  { name: "区块链",       symbol: "CHAIN9" },
  { name: "去中心化",     symbol: "DEFI9K" },
  { name: "智能合约",     symbol: "CONTR"  },
  { name: "矿工",         symbol: "MINE9K" },
  { name: "哈希算力",     symbol: "HASH9K" },
  { name: "钱包地址",     symbol: "ADDR9K" },
  { name: "私钥",         symbol: "PKEY9K" },
  { name: "助记词",       symbol: "SEED9K" },
  { name: "冷钱包",       symbol: "COLD9K" },
  { name: "热钱包",       symbol: "HOT9K"  },
  { name: "跨链桥",       symbol: "BRDG9K" },
  { name: "流动性池",     symbol: "POOL9K" },
  { name: "无常损失",     symbol: "IMPL9K" },
  { name: "质押挖矿",     symbol: "STKE9K" },
  { name: "空投猎人",     symbol: "DROP9K" },
  { name: "撸毛党",       symbol: "LURM9K" },
  { name: "女巫攻击",     symbol: "SYBIL"  },
  { name: "闪电贷",       symbol: "FLASH"  },
  { name: "预言机",       symbol: "ORACL"  },
  { name: "治理代币",     symbol: "GOV9K"  },
  { name: "链上数据",     symbol: "DATA9K" },
  { name: "二层网络",     symbol: "L2NET"  },
  { name: "侧链",         symbol: "SIDE9K" },
  { name: "分片",         symbol: "SHARD"  },
  { name: "零知识证明",   symbol: "ZKP9K"  },
  { name: "乐观卷积",     symbol: "OPTM9K" },
  { name: "钻石手",       symbol: "DIMD9K" },
  { name: "纸手",         symbol: "PPHD9K" },
  // Meme culture & slang
  { name: "韭菜收割机",   symbol: "HARV9K" },
  { name: "庄家砸盘",     symbol: "DUMP9K" },
  { name: "拉盘",         symbol: "PUMP9K" },
  { name: "对冲基金",     symbol: "HEDG9K" },
  { name: "散户逆袭",     symbol: "RETA9K" },
  { name: "土狗币",       symbol: "DOGE9K" },
  { name: "空气币",       symbol: "AIR9K"  },
  { name: "归零币",       symbol: "ZERO9K" },
  { name: "百亿市值",     symbol: "CAP9K"  },
  { name: "社区共识",     symbol: "CONS9K" },
  { name: "信仰充值",     symbol: "FAITH"  },
  { name: "上车",         symbol: "RIDE9K" },
  { name: "下车",         symbol: "EXIT9K" },
  { name: "套娃",         symbol: "NEST9K" },
  { name: "坐电梯",       symbol: "ELEV9K" },
  { name: "币圈暴发户",   symbol: "RICH9"  },
  { name: "数字黄金",     symbol: "DGOLD"  },
  { name: "数字石油",     symbol: "DOIL"   },
  { name: "彩虹图",       symbol: "RNBW9K" },
  { name: "恐惧贪婪",     symbol: "FNG9K"  },
  // Exchanges & projects
  { name: "火币传奇",     symbol: "HTLGD"  },
  { name: "抹茶交易所",   symbol: "MEXC9K" },
  { name: "币安合约",     symbol: "BNBF9K" },
  { name: "欧易合约",     symbol: "OKXF9K" },
  { name: "链上玩家",     symbol: "ONCH9K" },
  { name: "九五二七",     symbol: "NINE9K" },
  { name: "比特币大饼",   symbol: "BIGCAK" },
  { name: "以太小饼",     symbol: "SMCAK"  },
  { name: "山寨季",       symbol: "ALT9K"  },
  { name: "主力资金",     symbol: "MAIN9K" },
  { name: "量化交易",     symbol: "QUANT"  },
  { name: "搬砖套利",     symbol: "ARB9K"  },
  { name: "网格交易",     symbol: "GRID9K" },
  { name: "合约爆仓",     symbol: "FUT9K"  },
  { name: "永续合约",     symbol: "PERP9K" },
  { name: "资金费率",     symbol: "FUND9K" },
  { name: "多空比",       symbol: "LSRAT"  },
  { name: "开多",         symbol: "LONG9K" },
  { name: "开空",         symbol: "SHRT9K" },
  { name: "止损单",       symbol: "SL9K"   },
  { name: "止盈单",       symbol: "TP9K"   },
];

// ─── Fallback token pool (used when all news feeds fail) ─────────────────────
const FALLBACK_TOKEN_POOL = [
  { name: "DogeMoon",   symbol: "DMOON"  },
  { name: "PepeFi",     symbol: "PEPEFI" },
  { name: "Wen Lambo",  symbol: "WL9527" },
  { name: "ShibaRocket",symbol: "SHRKT"  },
  { name: "MoonshotX",  symbol: "MSHTX"  },
  { name: "GigaBull",   symbol: "GBULL"  },
  { name: "NinjaPepe",  symbol: "NINJA"  },
  { name: "CryptoFrog", symbol: "CFROG"  },
  { name: "Galaxy Doge",symbol: "GDOGE"  },
  { name: "Turbo Nine", symbol: "TURBO"  },
  { name: "HonkHonk",   symbol: "HONK"   },
  { name: "PumpIt",     symbol: "PUMP9K" },
];

// ─── RSS feeds (English + Chinese) ───────────────────────────────────────────
const NEWS_FEEDS: Array<{ url: string; lang: "en" | "zh" }> = [
  { url: "https://feeds.bbci.co.uk/news/world/rss.xml",                 lang: "en" },
  { url: "https://feeds.bbci.co.uk/news/technology/rss.xml",            lang: "en" },
  { url: "https://feeds.bbci.co.uk/zhongwen/simp/world/rss.xml",        lang: "zh" },
  { url: "https://news.google.com/rss?hl=zh-CN&gl=CN&ceid=CN:zh-Hans", lang: "zh" },
];

// ─── English stop words (filtered out when picking key words) ────────────────
const EN_STOP_WORDS = new Set([
  "the","a","an","is","in","on","at","to","for","of","and","or","but",
  "with","as","by","from","are","was","were","be","been","has","have",
  "had","will","would","could","should","may","might","it","its","this",
  "that","these","those","he","she","we","they","his","her","their","our",
  "after","over","new","up","out","how","what","when","who","why","says",
  "said","say","amid","into","than","about","more","not","no","its","does",
]);

// ─── Well-known acronyms that make good symbol prefixes ──────────────────────
const KNOWN_ACRONYMS = new Set([
  "AI","US","EU","UK","UN","GDP","IPO","CEO","CFO","CPI","FED","IMF",
  "WHO","NATO","ETF","NFT","BTC","ETH","BRICS","G7","G20","SEC","ESG","EV",
]);

// ─── Factory ABI (minimal) ────────────────────────────────────────────────────
const FACTORY_ABI = [
  "function createToken(string name_, string symbol_, uint256 treasuryFeeBP_, bytes32 salt_) external payable returns (address)",
  "function creationFee() external view returns (uint256)",
  "function enforceVanity() external view returns (bool)",
  "function getInitCodeHash(string name, string symbol, uint256 treasuryFeeBP, address deployer) external view returns (bytes32)",
  "function predictAddress(string name, string symbol, uint256 treasuryFeeBP, address deployer, bytes32 salt) external view returns (address predicted, bool valid)",
  "function totalTokens() external view returns (uint256)",
] as const;

// ═══════════════════════════════════════════════════════════════════════════════
// NEWS FETCHING & TOKEN GENERATION
// ═══════════════════════════════════════════════════════════════════════════════

/** Fetch a URL, following redirects up to maxRedirects times. */
async function fetchUrl(urlStr: string, maxRedirects = 4): Promise<string> {
  return new Promise((resolve, reject) => {
    const doGet = (current: string, left: number) => {
      const parsed = new URL(current);
      const mod = parsed.protocol === "https:" ? https : http;
      const req = mod.get(
        current,
        { headers: { "User-Agent": "Mozilla/5.0 (compatible; NewsTokenBot/1.0)" } },
        (res) => {
          const loc = res.headers.location;
          if ((res.statusCode === 301 || res.statusCode === 302 || res.statusCode === 307) && loc && left > 0) {
            const next = loc.startsWith("http") ? loc : `${parsed.protocol}//${parsed.host}${loc}`;
            doGet(next, left - 1);
            return;
          }
          let body = "";
          res.on("data", (chunk: Buffer) => (body += chunk.toString("utf8")));
          res.on("end", () => resolve(body));
          res.on("error", reject);
        }
      );
      req.setTimeout(8000, () => { req.destroy(); reject(new Error("timeout")); });
      req.on("error", reject);
    };
    doGet(urlStr, maxRedirects);
  });
}

/** Extract <title> text nodes from RSS XML, skipping the feed-level title. */
function parseRssTitles(xml: string): string[] {
  const re = /<title(?:\s[^>]*)?>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>/g;
  const results: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml)) !== null) {
    const t = m[1]
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&#\d+;/g, "")
      .trim();
    if (t.length > 5 && t.length < 120) results.push(t);
  }
  return results.slice(1); // index 0 is the feed/channel title
}

/**
 * Deterministically hash a short string to N uppercase letters.
 * Uses the A–Z alphabet minus I and O to avoid visual confusion.
 */
function hashToLetters(s: string, len = 3): string {
  const alpha = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  let h = 5381;
  for (const c of s) h = ((h << 5) + h + c.charCodeAt(0)) & 0x7fffffff;
  let out = "";
  for (let i = 0; i < len; i++) out += alpha[Math.abs(h >> (i * 5)) % alpha.length];
  return out;
}

/** Convert a raw news headline to a { name, symbol } token entry, or null. */
function headlineToToken(headline: string): { name: string; symbol: string } | null {
  const hasChinese = /[一-鿿]/.test(headline);

  if (hasChinese) {
    // Extract the first meaningful Chinese phrase (2–4 chars)
    const phrases = headline.match(/[一-鿿]{2,6}/g) ?? [];
    if (phrases.length === 0) return null;
    const keyPhrase = phrases[0].slice(0, 4);
    const name = keyPhrase;

    // Prefer a known English acronym already present in the headline
    const acronym = headline.match(/\b([A-Z]{2,5})\b/g)?.find(a => KNOWN_ACRONYMS.has(a));
    const symbol = acronym
      ? (acronym + "9K").slice(0, 6)
      : hashToLetters(keyPhrase) + "9K";

    return { name, symbol };
  } else {
    // English: remove punctuation, filter stop words, pick top 2 content words
    const words = headline
      .replace(/[^a-zA-Z0-9\s]/g, " ")
      .split(/\s+/)
      .filter(w => w.length > 2 && !EN_STOP_WORDS.has(w.toLowerCase()));

    if (words.length === 0) return null;

    const keyWords = words
      .slice(0, 2)
      .map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase());
    const name = keyWords.join("");

    // Symbol: initials of up to 5 significant words; fall back to prefix + "9K"
    const initials = words.slice(0, 5).map(w => w[0].toUpperCase()).join("");
    const symbol = initials.length >= 3
      ? initials.slice(0, 5)
      : keyWords[0].slice(0, 3).toUpperCase() + "9K";

    return { name, symbol };
  }
}

// ─── Live pool state ──────────────────────────────────────────────────────────
let liveTokenPool: Array<{ name: string; symbol: string }> = [];
let lastPoolRefreshMs = 0;

async function refreshNewsPool(): Promise<void> {
  log("Fetching latest news headlines…");

  const allHeadlines: string[] = [];

  const settled = await Promise.allSettled(
    NEWS_FEEDS.map(async (feed) => {
      const xml = await fetchUrl(feed.url);
      const titles = parseRssTitles(xml);
      log(`  [${feed.lang}] ${new URL(feed.url).hostname}: ${titles.length} headlines`);
      return titles.slice(0, 10);
    })
  );

  for (let i = 0; i < settled.length; i++) {
    const r = settled[i];
    if (r.status === "fulfilled") {
      allHeadlines.push(...r.value);
    } else {
      log(`  ⚠ Feed error (${new URL(NEWS_FEEDS[i].url).hostname}): ${(r.reason as Error).message}`);
    }
  }

  const seen = new Set<string>();
  const tokens: Array<{ name: string; symbol: string }> = [];

  for (const headline of allHeadlines) {
    const token = headlineToToken(headline);
    if (!token || seen.has(token.name)) continue;
    seen.add(token.name);
    tokens.push(token);
  }

  if (tokens.length > 0) {
    liveTokenPool = tokens;
    lastPoolRefreshMs = Date.now();
    log(`Token pool refreshed: ${tokens.length} news-based tokens`);
    const preview = tokens.slice(0, 6).map(t => `"${t.name}" (${t.symbol})`).join(" | ");
    log(`  Sample: ${preview}`);
  } else {
    log("⚠ No tokens from news — using fallback pool");
    liveTokenPool = [...FALLBACK_TOKEN_POOL];
    lastPoolRefreshMs = Date.now();
  }
}

function getTokenPool(): Array<{ name: string; symbol: string }> {
  return liveTokenPool.length > 0 ? liveTokenPool : FALLBACK_TOKEN_POOL;
}

// ═══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

function log(msg: string) {
  const ts = new Date().toISOString();
  console.log(`[${ts}] ${msg}`);
}

function randomBetween(min: number, max: number): number {
  return min + Math.random() * (max - min);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function pickRandom<T>(arr: readonly T[] | T[]): T {
  return arr[Math.floor(Math.random() * arr.length)];
}

/**
 * Mine a CREATE2 salt locally (pure CPU, no RPC).
 * Returns a Uint8Array(32) that produces an address ending in 0x9527
 * when deployed via the factory using CREATE2.
 *
 * Formula: keccak256(0xff ++ factory ++ salt ++ initCodeHash)[12:]
 * Valid when: uint16(address) == 0x9527
 */
function mineSaltLocal(
  factoryAddress: string,
  initCodeHash: string,
  maxIter: number
): Uint8Array {
  // Pre-build the 85-byte prefix that stays constant across iterations:
  //   1 byte  (0xff)
  //   20 bytes (factory address)
  //   32 bytes (salt)  ← overwritten each loop
  //   32 bytes (initCodeHash)
  const packed = new Uint8Array(1 + 20 + 32 + 32);
  packed[0] = 0xff;
  const factoryBytes = ethers.getBytes(factoryAddress);
  packed.set(factoryBytes, 1);
  const initHashBytes = ethers.getBytes(initCodeHash);
  packed.set(initHashBytes, 1 + 20 + 32); // initCodeHash at end

  const saltSlice = packed.subarray(21, 53); // 32-byte window for the salt

  for (let i = 0; i < maxIter; i++) {
    // Randomise salt in place
    crypto.getRandomValues(saltSlice);

    const hash = ethers.getBytes(ethers.keccak256(packed));
    // Address is last 20 bytes of hash; check last 2 bytes == 0x9527
    if (hash[30] === 0x95 && hash[31] === 0x27) {
      return Uint8Array.from(saltSlice); // return a copy
    }
  }
  throw new Error(`Could not mine vanity salt after ${maxIter.toLocaleString()} iterations`);
}

/** Append a JSON record to the log file (creates dirs if needed). */
function appendLog(record: object) {
  try {
    fs.mkdirSync(path.dirname(CONFIG.logFile), { recursive: true });
    fs.appendFileSync(CONFIG.logFile, JSON.stringify(record) + "\n");
  } catch (e) {
    log(`⚠ Could not write log: ${(e as Error).message}`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// GAS / COST ESTIMATION
// ═══════════════════════════════════════════════════════════════════════════════

async function printCostEstimate(
  provider: ethers.JsonRpcProvider,
  factory: ethers.Contract,
  wallet: ethers.Wallet,
  creationFee: bigint
) {
  console.log("\n════════════════════════════════════════════════════════");
  console.log("  COST ESTIMATE — X Layer Mainnet (OKB)");
  console.log("════════════════════════════════════════════════════════");

  const feeData  = await provider.getFeeData();
  const gasPrice = feeData.gasPrice ?? feeData.maxFeePerGas ?? 1_000_000n; // fallback 1 gwei
  const gasPriceGwei = Number(gasPrice) / 1e9;

  // Estimate gas for createToken using a dummy call on the view estimator
  // We use a generous upper bound since we cannot simulate CREATE2 easily without a real salt.
  // Empirically, deploying a complex ERC-20 + AMM via CREATE2 costs ~2.5 M gas on EVM L2s.
  const GAS_ESTIMATE_CREATE_TOKEN = 2_600_000n;
  const costPerToken = (GAS_ESTIMATE_CREATE_TOKEN * gasPrice) + creationFee;
  const costPerTokenOKB = Number(ethers.formatEther(costPerToken));

  const balance = await provider.getBalance(wallet.address);
  const balanceOKB = Number(ethers.formatEther(balance));

  // Reserve 0.002 OKB as buffer so the wallet isn't fully drained
  const RESERVE_OKB = 0.002;
  const deployableTokens = Math.max(
    0,
    Math.floor((balanceOKB - RESERVE_OKB) / costPerTokenOKB)
  );

  const { minIntervalMinutes: minI, maxIntervalMinutes: maxI } = CONFIG;
  const avgIntervalHrs = ((minI + maxI) / 2) / 60;
  const avgDeploysPerDay = 24 / avgIntervalHrs;

  console.log(`  Wallet address  : ${wallet.address}`);
  console.log(`  Wallet balance  : ${balanceOKB.toFixed(6)} OKB`);
  console.log(`  Current gas     : ${gasPriceGwei.toFixed(6)} gwei`);
  console.log(`  Est. gas/token  : ${GAS_ESTIMATE_CREATE_TOKEN.toLocaleString()} gas`);
  console.log(`  Factory fee     : ${ethers.formatEther(creationFee)} OKB`);
  console.log(`  ─────────────────────────────────────────────────────`);
  console.log(`  Cost per token  : ~${costPerTokenOKB.toFixed(6)} OKB`);
  console.log(`  Tokens afford.  : ~${deployableTokens.toLocaleString()} tokens`);
  console.log(`  ─────────────────────────────────────────────────────`);
  console.log(`  Interval        : ${minI}–${maxI} min  (avg ${(avgIntervalHrs * 60).toFixed(0)} min)`);
  console.log(`  ~Deploys/day    : ${avgDeploysPerDay.toFixed(1)}`);
  console.log(`  Daily OKB spend : ~${(avgDeploysPerDay * costPerTokenOKB).toFixed(6)} OKB`);

  if (deployableTokens > 0) {
    const daysRuntime = deployableTokens / avgDeploysPerDay;
    console.log(`  Est. runtime    : ~${daysRuntime.toFixed(1)} days`);
  } else {
    console.log(`  ⚠  Insufficient balance — top up OKB before running`);
  }
  console.log("════════════════════════════════════════════════════════\n");

  return { gasPrice, GAS_ESTIMATE_CREATE_TOKEN, costPerTokenOKB, deployableTokens };
}

// ═══════════════════════════════════════════════════════════════════════════════
// DEPLOY ONE TOKEN
// ═══════════════════════════════════════════════════════════════════════════════

async function deployOneToken(
  factory: ethers.Contract,
  wallet: ethers.Wallet,
  provider: ethers.JsonRpcProvider,
  creationFee: bigint,
  enforceVanity: boolean
): Promise<void> {
  // ~40% chance to deploy a Chinese meme token; otherwise use the news-based pool
  const pool = Math.random() < 0.4 ? CHINESE_MEME_POOL : getTokenPool();
  const token = pickRandom(pool);
  log(`Preparing token: "${token.name}" (${token.symbol})`);

  let saltHex: string;

  if (enforceVanity) {
    log("Mining vanity salt (address ending 0x9527)…");
    const mineStart = Date.now();

    const initCodeHash = await factory.getInitCodeHash(
      token.name,
      token.symbol,
      CONFIG.treasuryFeeBP,
      wallet.address
    ) as string;

    const saltBytes = mineSaltLocal(
      CONFIG.factoryAddress,
      initCodeHash,
      CONFIG.maxMiningIterations
    );
    saltHex = ethers.hexlify(saltBytes);

    const elapsed = ((Date.now() - mineStart) / 1000).toFixed(2);
    log(`Salt mined in ${elapsed}s → ${saltHex}`);
  } else {
    // Factory enforceVanity=false: use a random salt
    saltHex = ethers.hexlify(ethers.randomBytes(32));
    log(`Vanity enforcement off — using random salt ${saltHex}`);
  }

  const feeData = await provider.getFeeData();

  log("Sending createToken transaction…");
  const tx = await (factory.createToken as ethers.ContractMethod)(
    token.name,
    token.symbol,
    CONFIG.treasuryFeeBP,
    saltHex,
    { value: creationFee, gasLimit: 3_200_000n }
  );

  log(`Tx submitted: ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt) throw new Error("Transaction receipt is null");

  const gasUsed: bigint     = receipt.gasUsed;
  const effectiveGP: bigint = (receipt.gasPrice ?? feeData.gasPrice ?? 0n) as bigint;
  const actualCostWei: bigint = gasUsed * effectiveGP + (creationFee as bigint);

  // Parse TokenCreated event to get deployed address
  const iface = new ethers.Interface([
    "event TokenCreated(address indexed tokenAddress, address indexed deployer, string name, string symbol, uint256 treasuryFeeBP, bytes32 salt)",
  ]);
  let tokenAddress = "unknown";
  for (const logEntry of receipt.logs) {
    try {
      const parsed = iface.parseLog(logEntry);
      if (parsed?.name === "TokenCreated") {
        tokenAddress = parsed.args.tokenAddress as string;
      }
    } catch { /* not this event */ }
  }

  const record = {
    timestamp:   new Date().toISOString(),
    txHash:      tx.hash,
    block:       receipt.blockNumber,
    tokenAddress,
    name:        token.name,
    symbol:      token.symbol,
    treasuryFeeBP: CONFIG.treasuryFeeBP,
    salt:        saltHex,
    gasUsed:     gasUsed.toString(),
    gasPriceGwei: Number(effectiveGP) / 1e9,
    costOKB:     Number(ethers.formatEther(actualCostWei)),
    explorerUrl: `https://www.oklink.com/xlayer/tx/${tx.hash}`,
  };

  appendLog(record);
  log(`✅ Deployed ${token.symbol} at ${tokenAddress}`);
  log(`   Gas: ${gasUsed.toLocaleString()} | Cost: ${record.costOKB.toFixed(6)} OKB`);
  log(`   Explorer: ${record.explorerUrl}`);
}

// ═══════════════════════════════════════════════════════════════════════════════
// MAIN LOOP
// ═══════════════════════════════════════════════════════════════════════════════

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    console.error("ERROR: PRIVATE_KEY env var is not set.");
    console.error("  Run: PRIVATE_KEY=0x... npx ts-node scripts/periodic-deploy.ts");
    process.exit(1);
  }

  const isDryRun = process.env.DRY_RUN === "true";
  if (isDryRun) log("⚠  DRY RUN MODE — no transactions will be sent");

  const provider = new ethers.JsonRpcProvider(CONFIG.rpcUrl, CONFIG.chainId);
  const wallet   = new ethers.Wallet(privateKey, provider);
  const factory  = new ethers.Contract(CONFIG.factoryAddress, FACTORY_ABI, wallet);

  log(`Connected to X Layer mainnet (chain ${CONFIG.chainId})`);
  log(`Deployer: ${wallet.address}`);

  const creationFee   = await factory.creationFee() as bigint;
  const enforceVanity = await factory.enforceVanity() as boolean;
  const totalBefore   = await factory.totalTokens() as bigint;

  log(`Factory @ ${CONFIG.factoryAddress}`);
  log(`  creationFee  : ${ethers.formatEther(creationFee)} OKB`);
  log(`  enforceVanity: ${enforceVanity}`);
  log(`  totalTokens  : ${totalBefore.toString()}`);

  // Fetch news headlines before printing cost estimate
  await refreshNewsPool().catch((e: Error) => {
    log(`⚠ Initial news fetch failed (${e.message}) — using fallback pool`);
  });

  const { deployableTokens } = await printCostEstimate(
    provider, factory, wallet, creationFee
  );

  if (isDryRun) {
    log("Dry run complete — exiting.");
    return;
  }

  if (deployableTokens === 0) {
    log("Insufficient OKB balance. Please top up before running.");
    process.exit(1);
  }

  // Optional startup delay
  if (CONFIG.startDelayMinutes > 0) {
    log(`Waiting ${CONFIG.startDelayMinutes} minutes before first deployment…`);
    await sleep(CONFIG.startDelayMinutes * 60_000);
  }

  let deployCount = 0;
  let totalSpent  = 0;

  while (true) {
    // Refresh the news pool if it has gone stale
    if (Date.now() - lastPoolRefreshMs > CONFIG.newsRefreshIntervalMs) {
      await refreshNewsPool().catch((e: Error) =>
        log(`⚠ Pool refresh failed: ${e.message}`)
      );
    }

    deployCount++;
    log(`\n─── Deployment #${deployCount} ───────────────────────────────────`);

    try {
      const balanceBefore = await provider.getBalance(wallet.address);
      await deployOneToken(factory, wallet, provider, creationFee, enforceVanity);
      const balanceAfter  = await provider.getBalance(wallet.address);
      const spent = Number(ethers.formatEther(balanceBefore - balanceAfter));
      totalSpent += spent;
      log(`Cumulative spend: ${totalSpent.toFixed(6)} OKB across ${deployCount} token(s)`);
    } catch (err) {
      log(`⚠  Deployment failed: ${(err as Error).message}`);
      log("Will retry next cycle.");
    }

    // Random interval
    const intervalMin = randomBetween(CONFIG.minIntervalMinutes, CONFIG.maxIntervalMinutes);
    const intervalMs  = intervalMin * 60_000;
    const nextTime    = new Date(Date.now() + intervalMs);
    log(`Next deployment in ${intervalMin.toFixed(1)} min → ${nextTime.toISOString()}`);
    await sleep(intervalMs);
  }
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
