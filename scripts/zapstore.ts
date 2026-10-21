#!/usr/bin/env bun
// Publish one GitHub release to Zapstore as NIP-82 events, all marked
// linux-x86_64:
//
//   app      kind 32267  name, description, icon, screenshots (zapstore.yaml)
//   asset    kind 3063   one per package (AppImage, Flatpak): sha256, size,
//                        download URL, variant
//   release  kind 30063  version and notes, pointing at the assets
//
// zsp, Zapstore's own publisher, only handles APKs, so this builds the
// events zsp builds for Android with the Linux platform and package tags.
// nak signs them (ZAPSTORE_SIGNER: a bunker URL or nsec) and publishes each
// to every relay below; a relay refusing one fails the run.
//
// scripts/publish.sh runs it once the GitHub release exists, with the
// release's files downloaded and checked against its SHA256SUMS.txt:
//
//   ZAPSTORE_SIGNER=bunker://... scripts/zapstore.ts v2026.10.21-build.1 \
//     WhiteNoise-v2026.10.21-build.1-x86_64.AppImage \
//     WhiteNoise-v2026.10.21-build.1-x86_64.flatpak
//
// Zapstore's Android app and zapstore.dev list only android-arm64-v8a
// today, so these events are reachable by NIP-82 queries but have no store
// page yet.
//
// ponytail: the icon, screenshots and packages are GitHub URLs, not Blossom
// blobs; each asset event's sha256 still pins its package. Upgrade: upload
// them with `nak blossom upload` to Zapstore's server.
import { $ } from "bun";

const APP_ID = "dev.ipf.whitenoise";
const PLATFORM = "linux-x86_64";
const RELAYS = ["wss://relay.zapstore.dev", "wss://relay.cyberguy.fyi"];
// The Zapstore catalog community; zsp adds it to every app it publishes.
const CATALOG = "acfeaea6e51420e8068fac446ca9d17d7a9ef6a5d20d93894e50fee3d4902a84";
const GITHUB = "marmot-protocol/whitenoise-linux";
// The packages a release can list, by file suffix: MIME type, and the
// variant tag clients choose between.
const FORMATS = [
  { suffix: ".AppImage", mime: "application/vnd.appimage", variant: "appimage" },
  { suffix: ".flatpak", mime: "application/vnd.flatpak", variant: "flatpak" },
];

const [tag, ...packages] = Bun.argv.slice(2);
if (!tag || packages.length === 0) {
  console.error("Usage: scripts/zapstore.ts <tag> <package>...");
  process.exit(2);
}
const signer = process.env.ZAPSTORE_SIGNER;
if (!signer) {
  console.error("Set ZAPSTORE_SIGNER to the publisher's bunker URL or nsec.");
  process.exit(2);
}

// v2026.10.21-build.1 is APP_VERSION 2026.10.21+1 (scripts/version.sh). Read
// from the tag, not the checkout, so any checkout can publish any release.
const tagVersion = tag.match(/^v(\d{4}\.\d+\.\d+)-build\.(\d+)$/);
if (!tagVersion) {
  console.error(`Release tag must look like v2026.10.21-build.1, got '${tag}'.`);
  process.exit(2);
}
const version = `${tagVersion[1]}+${tagVersion[2]}`;

const root = `${import.meta.dir}/..`;
const commit = (await $`git -C ${root} rev-parse ${`${tag}^{commit}`}`.text()).trim();
// The notes scripts/release.sh wrote into the tag, as on the GitHub release.
const notes = (await $`git -C ${root} tag -l ${"--format=%(contents:body)"} ${tag}`.text()).trim();
const config = Bun.YAML.parse(await Bun.file(`${root}/zapstore.yaml`).text());
// Zapstore whitelists only zapstore.yaml's pubkey. Another key's events would
// be refused there but still land on the other relays, so refuse them first.
const publisher = (await $`nak decode ${config.pubkey}`.text()).trim();

// zapstore.yaml names repository files; serve them from the tag.
const fileUrl = (path: string) => `https://raw.githubusercontent.com/${GITHUB}/${tag}/${path}`;
// Hash every package before signing anything, so a bad path or an unknown
// format fails before the first event goes out.
const assets = [];
for (const path of packages) {
  const name = path.split("/").pop()!;
  const format = FORMATS.find((f) => name.endsWith(f.suffix));
  if (!format) {
    console.error(`${name} is not an AppImage or a Flatpak bundle.`);
    process.exit(2);
  }
  const file = Bun.file(path);
  const hasher = new Bun.CryptoHasher("sha256");
  for await (const chunk of file.stream()) {
    hasher.update(chunk);
  }
  assets.push({ name, format, size: file.size, sha256: hasher.digest("hex") });
}

// Sign once, then send the same signed event to each relay in turn.
async function publish(event: { kind: number; content: string; tags: string[][] }) {
  const signed = await $`nak event < ${new Response(JSON.stringify(event))}`
    .env({ ...process.env, NOSTR_SECRET_KEY: signer })
    .json();
  if (signed.pubkey !== publisher) {
    throw new Error(`ZAPSTORE_SIGNER signs as ${signed.pubkey}; zapstore.yaml publishes as ${publisher}.`);
  }
  for (const relay of RELAYS) {
    await $`nak event ${relay} < ${new Response(JSON.stringify(signed))}`.quiet();
  }
  console.log(`kind ${signed.kind}: ${signed.id}`);
  return signed.id as string;
}

await publish({
  kind: 32267,
  content: config.description,
  tags: [
    ["d", APP_ID],
    ["name", config.name],
    ["summary", config.summary],
    ["icon", fileUrl(config.icon)],
    ...config.images.map((path: string) => ["image", fileUrl(path)]),
    ...config.tags.map((name: string) => ["t", name]),
    ["url", config.website],
    ["repository", config.repository],
    ["f", PLATFORM],
    ["license", config.license],
    ["h", CATALOG],
  ],
});

const assetIds = [];
for (const asset of assets) {
  assetIds.push(
    await publish({
      kind: 3063,
      content: "",
      tags: [
        ["i", APP_ID],
        ["x", asset.sha256],
        ["version", version],
        ["url", `https://github.com/${GITHUB}/releases/download/${tag}/${asset.name}`],
        ["m", asset.format.mime],
        ["size", String(asset.size)],
        ["f", PLATFORM],
        ["filename", asset.name],
        ["variant", asset.format.variant],
        ["commit", commit],
      ],
    }),
  );
}

await publish({
  kind: 30063,
  content: notes,
  tags: [
    ["i", APP_ID],
    ["version", version],
    ["d", `${APP_ID}@${version}`],
    ["c", "main"],
    ["f", PLATFORM],
    ...assetIds.map((id) => ["e", id]),
  ],
});
