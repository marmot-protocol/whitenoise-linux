#!/usr/bin/env bun
// Publish one release to Zapstore as NIP-82 events, all marked
// linux-x86_64:
//
//   app      kind 32267  name, description, icon, screenshots (zapstore.yaml)
//   asset    kind 3063   the AppImage: sha256, size, download URL
//   release  kind 30063  version and notes, pointing at the asset
//
// zsp, Zapstore's own publisher, only handles APKs, so this builds the
// events zsp builds for Android with the Linux platform and AppImage tags.
// nak signs them (ZAPSTORE_SIGNER: a bunker URL or nsec) and publishes each
// to every relay below; a relay refusing one fails the run.
//
//   ZAPSTORE_SIGNER=bunker://... scripts/zapstore.ts v2026.10.21-build.1 \
//     dist/WhiteNoise-v2026.10.21-build.1-x86_64.AppImage
//
// Zapstore's Android app and zapstore.dev list only android-arm64-v8a
// today, so these events are reachable by NIP-82 queries but have no store
// page yet.
//
// ponytail: the icon, screenshots and AppImage are GitHub URLs, not Blossom
// blobs; the asset event's sha256 still pins the AppImage. Upgrade: upload
// them with `nak blossom upload` to Zapstore's server.
import { $ } from "bun";

const APP_ID = "dev.ipf.whitenoise";
const PLATFORM = "linux-x86_64";
const RELAYS = ["wss://relay.zapstore.dev", "wss://relay.cyberguy.fyi"];
// The Zapstore catalog community; zsp adds it to every app it publishes.
const CATALOG = "acfeaea6e51420e8068fac446ca9d17d7a9ef6a5d20d93894e50fee3d4902a84";
const GITHUB = "marmot-protocol/whitenoise-linux";

const [tag, appimage] = Bun.argv.slice(2);
if (!tag || !appimage) {
  console.error("Usage: scripts/zapstore.ts <tag> <AppImage>");
  process.exit(2);
}
const signer = process.env.ZAPSTORE_SIGNER;
if (!signer) {
  console.error("Set ZAPSTORE_SIGNER to the publisher's bunker URL or nsec.");
  process.exit(2);
}

const root = `${import.meta.dir}/..`;
const version = (await $`bash ${root}/scripts/version.sh ${tag}`.text()).trim();
const commit = (await $`git -C ${root} rev-parse ${`${tag}^{commit}`}`.text()).trim();
// The notes scripts/release.sh wrote into the tag, as on the GitHub release.
const notes = (await $`git -C ${root} tag -l ${"--format=%(contents:body)"} ${tag}`.text()).trim();
const config = Bun.YAML.parse(await Bun.file(`${root}/zapstore.yaml`).text());

// zapstore.yaml names repository files; serve them from the tag.
const fileUrl = (path: string) => `https://raw.githubusercontent.com/${GITHUB}/${tag}/${path}`;
const appimageName = appimage.split("/").pop();
const file = Bun.file(appimage);
const hasher = new Bun.CryptoHasher("sha256");
for await (const chunk of file.stream()) {
  hasher.update(chunk);
}

// Sign once, then send the same signed event to each relay in turn.
async function publish(event: { kind: number; content: string; tags: string[][] }) {
  const signed = await $`nak event < ${new Response(JSON.stringify(event))}`
    .env({ ...process.env, NOSTR_SECRET_KEY: signer })
    .json();
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

const assetId = await publish({
  kind: 3063,
  content: "",
  tags: [
    ["i", APP_ID],
    ["x", hasher.digest("hex")],
    ["version", version],
    ["url", `https://github.com/${GITHUB}/releases/download/${tag}/${appimageName}`],
    ["m", "application/vnd.appimage"],
    ["size", String(file.size)],
    ["f", PLATFORM],
    ["filename", appimageName],
    ["commit", commit],
  ],
});

await publish({
  kind: 30063,
  content: notes,
  tags: [
    ["i", APP_ID],
    ["version", version],
    ["d", `${APP_ID}@${version}`],
    ["c", "main"],
    ["f", PLATFORM],
    ["e", assetId],
  ],
});
