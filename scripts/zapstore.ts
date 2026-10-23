#!/usr/bin/env bun
// Publish one GitHub release to Zapstore and Orchard as NIP-82 events, all marked
// linux-x86_64:
//
//   app      kind 32267  name, description, icon, screenshots (zapstore.yaml)
//   asset    kind 3063   AppImage, Flatpak bundle, OCI manifest/config/layer:
//                        sha256, size, download URL, variant or target
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
//     WhiteNoise-v2026.10.21-build.1-x86_64.flatpak \
//     dev.ipf.whitenoise-linux-x86_64.asset.json
//
// Zapstore's Android app and zapstore.dev list only android-arm64-v8a
// today, so these events are reachable by NIP-82 queries but have no store
// page yet.
//
// ponytail: the icon, screenshots and packages are GitHub URLs, not Blossom
// blobs; each asset event's sha256 still pins its package. Upgrade: upload
// them with `nak blossom upload` to Zapstore's server.
import { $ } from "bun";
import { lstat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";

const APP_ID = "dev.ipf.whitenoise";
const PLATFORM = "linux-x86_64";
const RELAYS = [
  "wss://relay.cyberguy.fyi",
  "wss://relay.orchard.rocks",
  "wss://relay.ditto.pub",
  "wss://relay.zapstore.dev",
];
const ORCHARD_NAME = `${APP_ID}-${PLATFORM}`;
const MANIFEST_MIME = "application/vnd.oci.image.manifest.v1+json";
const CONFIG_MIME = "application/vnd.oci.image.config.v1+json";
const LAYER_MIME = "application/vnd.oci.image.layer.v1.tar+gzip";
// The Zapstore catalog community; zsp adds it to every app it publishes.
const CATALOG =
  "acfeaea6e51420e8068fac446ca9d17d7a9ef6a5d20d93894e50fee3d4902a84";
const GITHUB = "marmot-protocol/whitenoise-linux";
// The packages a release can list, by file suffix: MIME type, and the
// variant tag clients choose between.
const FORMATS = [
  {
    suffix: ".AppImage",
    mime: "application/vnd.appimage",
    variant: "appimage",
  },
  { suffix: ".flatpak", mime: "application/vnd.flatpak", variant: "flatpak" },
];

const [tag, ...paths] = Bun.argv.slice(2);
if (!tag || paths.length !== 3) {
  console.error(
    "Usage: scripts/zapstore.ts <tag> <AppImage> <flatpak> <Orchard .asset.json>",
  );
  process.exit(2);
}
const signer = process.env.ZAPSTORE_SIGNER;
if (!signer) {
  console.error("Set ZAPSTORE_SIGNER to the publisher's bunker URL or nsec.");
  process.exit(2);
}

// v2026.10.21-build.1 is APP_VERSION 2026.10.21+1 (scripts/version.sh). Read
// from the tag, not the checkout, so any checkout can publish any release.
const tagVersion = tag.match(
  /^v(\d{4})\.([1-9]|1[0-2])\.([1-9]|[12][0-9]|3[01])-build\.([1-9][0-9]*)$/,
);
if (!tagVersion) {
  console.error(
    `Release tag must look like v2026.10.21-build.1, got '${tag}'.`,
  );
  process.exit(2);
}
const [, year, month, day, revision] = tagVersion;
const days = [
  31,
  Number(year) % 4 === 0 &&
  (Number(year) % 100 !== 0 || Number(year) % 400 === 0)
    ? 29
    : 28,
  31,
  30,
  31,
  30,
  31,
  31,
  30,
  31,
  30,
  31,
];
if (Number(day) > days[Number(month) - 1]) {
  throw new Error(`Invalid release date in ${tag}.`);
}
const version = `${year}.${month}.${day}+${revision}`;

const root = `${import.meta.dir}/..`;
const commit = (
  await $`git -C ${root} rev-parse ${`${tag}^{commit}`}`.text()
).trim();
// The notes scripts/release.sh wrote into the tag, as on the GitHub release.
const notes = (
  await $`git -C ${root} tag -l ${"--format=%(contents:body)"} ${tag}`.text()
).trim();
const config = Bun.YAML.parse(await Bun.file(`${root}/zapstore.yaml`).text());
// Zapstore whitelists only zapstore.yaml's pubkey. Another key's events would
// be refused there but still land on the other relays, so refuse them first.
const publisher = (await $`nak decode ${config.pubkey}`.text()).trim();

// zapstore.yaml names repository files; serve them from the tag.
const fileUrl = (path: string) =>
  `https://raw.githubusercontent.com/${GITHUB}/${tag}/${path}`;
type Component = {
  filename: string;
  sha256: string;
  size: number;
  mime: string;
  url: null;
};
type Prepared = Component & {
  schema: number;
  app_id: string;
  version: string;
  platform: string;
  package: string;
  layout: string;
  components: Component[];
};
type Asset = {
  name: string;
  sha256: string;
  size: number;
  mime: string;
  variant?: string;
  target?: string;
};

// Hash packages and large compressed layers without buffering their contents.
async function hashFile(path: string) {
  const file = Bun.file(path);
  const hasher = new Bun.CryptoHasher("sha256");
  let size = 0;
  for await (const chunk of file.stream()) {
    hasher.update(chunk);
    size += chunk.length;
  }
  return { size, sha256: hasher.digest("hex") };
}

function requireValid(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(`Invalid Orchard asset: ${message}`);
  }
}

// Metadata names only exact siblings, never paths, URLs or an OCI archive.
// Reject symlinks too: bytes outside the prepared directory are not components.
async function sibling(directory: string, name: string) {
  requireValid(
    typeof name === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name),
    "unsafe sibling filename",
  );
  const path = join(directory, name);
  requireValid(
    (await lstat(path)).isFile(),
    `${name} must be a regular sibling file`,
  );
  return path;
}

function validateComponent(component: Component, expectedName?: string) {
  requireValid(
    component && typeof component === "object",
    "missing component record",
  );
  requireValid(
    typeof component.sha256 === "string" &&
      /^[0-9a-f]{64}$/.test(component.sha256),
    "expected bare SHA-256",
  );
  requireValid(
    component.filename === (expectedName ?? component.sha256),
    "unexpected component filename",
  );
  requireValid(
    Number.isSafeInteger(component.size) && component.size > 0,
    "invalid component size",
  );
  requireValid(
    component.url === null,
    "prepared URLs must be null; hosting is assigned at publication",
  );
}

async function orchardAssets(path: string): Promise<Asset[]> {
  requireValid(
    basename(path) === `${ORCHARD_NAME}.asset.json`,
    "unexpected metadata filename",
  );
  const directory = dirname(path);
  const metadata = await sibling(directory, basename(path));
  const prepared: Prepared = await Bun.file(metadata).json();
  requireValid(
    prepared && typeof prepared === "object",
    "missing prepared record",
  );
  requireValid(
    prepared.schema === 2 &&
      prepared.package === "flatpak-oci" &&
      prepared.mime === MANIFEST_MIME,
    "expected schema 2 flatpak-oci manifest",
  );
  requireValid(
    prepared.app_id === APP_ID &&
      prepared.version === version &&
      prepared.platform === PLATFORM,
    "app, version or platform differs from this release",
  );
  requireValid(
    typeof prepared.layout === "string" &&
      /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(prepared.layout),
    "layout must name a sibling directory (not required for direct downloads)",
  );
  validateComponent(prepared, `${ORCHARD_NAME}.manifest.json`);
  requireValid(
    Array.isArray(prepared.components) && prepared.components.length === 2,
    "expected exactly one config and one layer",
  );
  const manifestPath = await sibling(directory, prepared.filename);
  const manifestHash = await hashFile(manifestPath);
  requireValid(
    manifestHash.sha256 === prepared.sha256 &&
      manifestHash.size === prepared.size,
    "manifest hash or size differs",
  );
  const manifest = await Bun.file(manifestPath).json();
  requireValid(
    manifest?.schemaVersion === 2 && manifest.mediaType === MANIFEST_MIME,
    "expected OCI schema 2 image manifest",
  );
  requireValid(
    Array.isArray(manifest.layers) && manifest.layers.length === 1,
    "expected exactly one manifest layer",
  );
  const descriptors = [manifest.config, ...manifest.layers];
  const result: Asset[] = [
    {
      name: prepared.filename,
      ...manifestHash,
      mime: prepared.mime,
      target: prepared.package,
    },
  ];
  const names = new Set([prepared.filename]);
  for (const [index, component] of prepared.components.entries()) {
    validateComponent(component);
    requireValid(!names.has(component.filename), "duplicate component");
    names.add(component.filename);
    requireValid(
      component.mime === (index === 0 ? CONFIG_MIME : LAYER_MIME),
      "unexpected config or layer MIME",
    );
    const descriptor = descriptors[index];
    requireValid(
      descriptor &&
        descriptor.digest === `sha256:${component.sha256}` &&
        descriptor.size === component.size &&
        descriptor.mediaType === component.mime,
      "component descriptor differs from prepared metadata",
    );
    const componentPath = await sibling(directory, component.filename);
    const actual = await hashFile(componentPath);
    requireValid(
      actual.sha256 === component.sha256 && actual.size === component.size,
      `${component.filename} hash or size differs`,
    );
    if (index === 0) {
      const config = await Bun.file(componentPath).json();
      requireValid(
        config?.os === "linux" && config.architecture === "amd64",
        "config platform differs",
      );
      requireValid(
        config.config?.Labels?.["org.flatpak.ref"] ===
          `app/${APP_ID}/x86_64/stable`,
        "config Flatpak ref differs",
      );
    }
    result.push({
      name: component.filename,
      ...actual,
      mime: component.mime,
      target: prepared.package,
    });
  }
  return result;
}

// Resolve and validate ALL five assets before the first signature or relay
// publication. Missing Orchard outputs must never make an old-style release.
const assets: Asset[] = [];
const used = new Set<string>();
let preparedPath: string | undefined;
for (const path of paths) {
  const name = basename(path);
  if (name === `${ORCHARD_NAME}.asset.json`) {
    requireValid(!preparedPath, "duplicate metadata input");
    preparedPath = path;
    continue;
  }
  const format = FORMATS.find(
    (f) => name === `WhiteNoise-${tag}-x86_64${f.suffix}`,
  );
  if (!format || used.has(format.variant)) {
    throw new Error(`Unexpected or duplicate package: ${name}`);
  }
  used.add(format.variant);
  assets.push({
    name,
    mime: format.mime,
    variant: format.variant,
    ...(await hashFile(path)),
  });
}
if (!preparedPath || used.size !== FORMATS.length) {
  throw new Error(
    "Release requires AppImage, Flatpak bundle and Orchard prepared metadata.",
  );
}
// Orchard chooses the first compatible referenced asset. Its manifest must
// precede the manual .flatpak bundle so installs retain the OCI component graph.
assets.unshift(...(await orchardAssets(preparedPath)));

// Sign once, then send the same signed event to each relay in turn.
async function publish(event: {
  kind: number;
  content: string;
  tags: string[][];
}) {
  const signed = await $`nak event < ${new Response(JSON.stringify(event))}`
    .env({ ...process.env, NOSTR_SECRET_KEY: signer })
    .json();
  if (signed.pubkey !== publisher) {
    throw new Error(
      `ZAPSTORE_SIGNER signs as ${signed.pubkey}; zapstore.yaml publishes as ${publisher}.`,
    );
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
    ...config.images.map((path: string) => ["screenshot", fileUrl(path)]),
    ...config.tags.map((name: string) => ["t", name]),
    ["t", "Network"],
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
        [
          "url",
          `https://github.com/${GITHUB}/releases/download/${tag}/${asset.name}`,
        ],
        ["m", asset.mime],
        ["size", String(asset.size)],
        ["f", PLATFORM],
        ["filename", asset.name],
        ...(asset.variant ? [["variant", asset.variant]] : []),
        ...(asset.target ? [["T", asset.target]] : []),
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
    ["a", `32267:${publisher}:${APP_ID}`],
    ["c", "stable"],
    ["f", PLATFORM],
    ...assetIds.map((id) => ["e", id]),
  ],
});
