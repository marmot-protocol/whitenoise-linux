#!/usr/bin/env bun
import { createPublicKey, verify } from "node:crypto";
import { readFileSync, writeFileSync, statSync } from "node:fs";
import { basename, resolve } from "node:path";

export function macVersion(version) {
  const match =
    /^v?(\d{4})\.(\d{1,2})\.(\d{1,2})(?:\+|-build\.)([1-9]\d*)$/.exec(version);
  if (!match) {
    throw new Error(
      "macOS version must be YYYY.M.D+REV or vYYYY.M.D-build.REV",
    );
  }
  const [, year, month, day, revision] = match;
  const date = new Date(Date.UTC(Number(year), Number(month) - 1, Number(day)));
  if (
    date.getUTCFullYear() !== Number(year) ||
    date.getUTCMonth() + 1 !== Number(month) ||
    date.getUTCDate() !== Number(day)
  ) {
    throw new Error("Invalid macOS release calendar date");
  }
  return {
    build: `${year}${month.padStart(2, "0")}${day.padStart(2, "0")}.${revision}`,
    display: `${Number(year)}.${Number(month)}.${Number(day)}`,
    tag: `v${Number(year)}.${Number(month)}.${Number(day)}-build.${revision}`,
  };
}

export function verifyPayload(payload, signature, publicKey) {
  const rawKey = Buffer.from(publicKey.trim(), "base64");
  if (rawKey.length !== 32) {
    throw new Error("Sparkle public key must contain 32 bytes");
  }
  const key = createPublicKey({
    key: Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"),
      rawKey,
    ]),
    format: "der",
    type: "spki",
  });
  if (!verify(null, payload, key, Buffer.from(signature, "base64"))) {
    throw new Error(
      "Sparkle archive signature does not match the committed public key",
    );
  }
}

export function appcast({
  version,
  arch,
  archive,
  signature,
  length,
  date = new Date(),
}) {
  if (!["arm64", "amd64"].includes(arch)) {
    throw new Error("Unsupported Sparkle feed architecture");
  }
  if (!/^[A-Za-z0-9+/]{86}==$/.test(signature)) {
    throw new Error("Invalid Ed25519 signature");
  }
  const { build, display, tag } = macVersion(version);
  const url = `https://github.com/marmot-protocol/whitenoise-linux/releases/download/${encodeURIComponent(tag)}/${encodeURIComponent(basename(archive))}`;
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>White Noise for macOS (${arch})</title>
<link>https://github.com/marmot-protocol/whitenoise-linux/releases</link>
<description>Authenticated White Noise updates</description><language>en</language>
<item><title>White Noise ${display}</title><pubDate>${date.toUTCString()}</pubDate>
<sparkle:version>${build}</sparkle:version><sparkle:shortVersionString>${display}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
<enclosure url="${url}" sparkle:edSignature="${signature}" length="${length}" type="application/octet-stream"/>
</item></channel></rss>
`;
}

function signUpdate(tool, secret, args) {
  const result = Bun.spawnSync([tool, "--ed-key-file", "-", ...args], {
    stdin: Buffer.from(secret + "\n"),
    stdout: "pipe",
    stderr: "pipe",
  });
  // Do not forward signing-tool diagnostics: malformed-secret errors can
  // include secret input. The key itself is never a process argument/file.
  if (result.exitCode !== 0) {
    throw new Error(
      "Sparkle sign_update failed; check signing-key configuration",
    );
  }
  return Buffer.from(result.stdout).toString().trim();
}

if (import.meta.main) {
  const [command, ...args] = Bun.argv.slice(2);
  if (command === "versions") {
    const { build, display } = macVersion(args[0]);
    console.log(build, display);
  } else if (command === "publish") {
    const [archive, version, arch, sparkle, publicKeyFile, output] = args;
    const secret = process.env.WN_SPARKLE_PRIVATE_KEY?.trim();
    if (
      !secret ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(secret) ||
      ![32, 96].includes(Buffer.from(secret, "base64").length)
    ) {
      throw new Error(
        "WN_SPARKLE_PRIVATE_KEY must be a base64 Sparkle seed export (32 bytes) or legacy export (96 bytes)",
      );
    }
    const tool = resolve(sparkle, "bin/sign_update");
    const signature = signUpdate(tool, secret, ["-p", archive]);
    verifyPayload(
      readFileSync(archive),
      signature,
      readFileSync(publicKeyFile, "utf8"),
    );
    writeFileSync(
      output,
      appcast({
        version,
        arch,
        archive,
        signature,
        length: statSync(archive).size,
      }),
    );
    // Sparkle 2.9+ embeds an authenticated signature directly in this XML.
    signUpdate(tool, secret, [output]);
    signUpdate(tool, secret, ["--verify", output]);
    console.log(`Published authenticated ${basename(output)}`);
  } else {
    throw new Error(
      "Usage: sparkle-package.js versions VERSION | publish ARCHIVE VERSION ARCH SPARKLE PUBLIC_KEY OUTPUT",
    );
  }
}
