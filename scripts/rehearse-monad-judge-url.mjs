#!/usr/bin/env node

import {fileURLToPath} from "node:url";
import {resolve} from "node:path";

import {
  rehearsePublicTestnetUrl,
  validateSettlementEvidence as validatePublicSettlementEvidence
} from "./rehearse-public-testnet-url.mjs";

const MONAD_WALLET_NETWORK = {
  name: "Monad Testnet",
  chainId: 10143,
  rpcUrl: "https://testnet-rpc.monad.xyz",
  nativeCurrency: "MON",
  explorerUrl: "https://testnet.monadexplorer.com"
};

export function rehearseJudgeUrl(baseUrl, options = {}) {
  return rehearsePublicTestnetUrl(baseUrl, {
    evidencePath: options.evidencePath,
    expectedChainId: MONAD_WALLET_NETWORK.chainId,
    expectedNetworkName: MONAD_WALLET_NETWORK.name,
    expectedWalletNetwork: MONAD_WALLET_NETWORK,
    deploymentCheck: "monad-deployment-and-readiness"
  });
}

export function validateSettlementEvidence(evidence, state, health) {
  return validatePublicSettlementEvidence(evidence, state, health, MONAD_WALLET_NETWORK.chainId);
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--url") options.url = argv[++index];
    else if (argument === "--evidence") options.evidencePath = argv[++index];
    else if (argument === "-h" || argument === "--help") options.help = true;
    else throw new Error(`unknown argument: ${argument}`);
  }
  return options;
}

function usage() {
  return `Usage: node scripts/rehearse-monad-judge-url.mjs --url URL [--evidence FILE]\n\nValidates the hosted Monad judge surface and optionally a downloaded settlement evidence file. Public URLs must use HTTPS; loopback HTTP is accepted for local rehearsal.`;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.help) {
      console.log(usage());
    } else {
      if (!options.url) throw new Error("--url is required");
      console.log(JSON.stringify(await rehearseJudgeUrl(options.url, options), null, 2));
    }
  } catch (error) {
    console.error(`Monad judge rehearsal failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
