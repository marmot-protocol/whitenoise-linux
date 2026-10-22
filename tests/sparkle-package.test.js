import { describe, expect, test } from "bun:test";
import { generateKeyPairSync, sign } from "node:crypto";
import { macVersion, verifyPayload } from "../scripts/sparkle-package.js";

describe("Sparkle macOS release metadata", () => {
  test("app and tagged versions have identical monotonic build numbers", () => {
    expect(macVersion("2026.9.5+12")).toEqual({
      build: "20260905.12",
      display: "2026.9.5",
      tag: "v2026.9.5-build.12",
    });
    expect(macVersion("v2026.9.5-build.12")).toEqual(macVersion("2026.9.5+12"));
    const builds = ["2026.9.5+9", "2026.9.5+10", "2026.9.6+1"].map(
      (version) => macVersion(version).build,
    );
    expect(
      builds.toSorted((a, b) => a.localeCompare(b, "en", { numeric: true })),
    ).toEqual(builds);
  });
  test("rejects impossible calendar dates and invalid revisions", () => {
    for (const version of [
      "2026.2.29+1",
      "2026.13.1+1",
      "2026.4.31+2",
      "2026.1.1+0",
      "2026.1.1",
      "2026.1.1+1-unsigned",
    ]) {
      expect(() => macVersion(version)).toThrow();
    }
    expect(macVersion("2028.2.29+1").build).toBe("20280229.1");
  });
});

describe("Sparkle publisher trust", () => {
  const keys = generateKeyPairSync("ed25519");
  const publicKey = keys.publicKey
    .export({ format: "der", type: "spki" })
    .subarray(-32)
    .toString("base64");
  const payload = Buffer.from("authenticated macOS archive payload");
  const signature = sign(null, payload, keys.privateKey).toString("base64");
  test("rejects tampered archives and a different publisher key", () => {
    expect(() =>
      verifyPayload(Buffer.from("tampered"), signature, publicKey),
    ).toThrow();
    const other = generateKeyPairSync("ed25519")
      .publicKey.export({ format: "der", type: "spki" })
      .subarray(-32)
      .toString("base64");
    expect(() => verifyPayload(payload, signature, other)).toThrow();
  });
});
