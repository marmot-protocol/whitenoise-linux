// Render Sidecar's own CSS backgrounds without porting its browser renderer.
// Bun and Chromium are needed only to regenerate these embedded PNGs.
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const revision = "3aaebf9dc7beb9924c6e1f9bc060cecbc1be6f8f";
const upstream = `https://raw.githubusercontent.com/dmnyc/sidecar/${revision}/`;
const themes = [
  ["speakeasy", "quilt"],
  ["film-noir", "film"],
  ["brownstone", "masonry"],
  ["nixie", "mesh"],
  ["metropolis", "rays"],
  ["industria", "sunburst"],
  ["aegean", "meander"],
  ["par-avion", "airmail-map"],
  ["bauhaus", "circle-grid"],
  ["ben-day", "comic-dots"],
  ["cast-iron", "cast-metal"],
  ["constellation", "star-atlas"],
  ["departures", "split-flaps"],
  ["jazz-age", "jazz-stage"],
  ["mycelium", "fungal-threads"],
  ["populuxe", "circle-lattice"],
  ["sleepy-hollow", "hollow-night"],
  ["turnstile", "subway-tile"],
  ["ukiyo-e", "woodblock-waves"],
  ["wabi-sabi", "kintsugi"],
  ["werkstatte", "secession-grid"],
] as const;
const files = new Map<string, string>();
for (const path of [
  "styles.css",
  "themes/patterns.css",
  ...themes.map(([theme]) => `themes/${theme}.css`),
]) {
  const response = await fetch(upstream + path);
  if (!response.ok) {
    throw new Error(`${path}: HTTP ${response.status}`);
  }
  files.set(path, await response.text());
}
// Fetch every plate named by the pinned pattern sheet, including wide variants.
const artwork = new Set(
  [
    ...files.get("themes/patterns.css")!.matchAll(/url\(([^)'"\s]+\.svg)\)/g),
  ].map(([, name]) => name),
);
for (const name of artwork) {
  const path = `themes/${name}`;
  const response = await fetch(upstream + path);
  if (!response.ok) {
    throw new Error(`${path}: HTTP ${response.status}`);
  }
  files.set(path, await response.text());
}
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/") {
      const theme = url.searchParams.get("theme");
      if (!themes.some(([name]) => name === theme)) {
        return new Response("Unknown theme", { status: 404 });
      }
      return new Response(
        `<!doctype html><html data-theme="${theme}" data-sky="orion"><head>
<link rel="stylesheet" href="styles.css"><link rel="stylesheet" href="themes/${theme}.css">
<link rel="stylesheet" href="themes/patterns.css"><style>html,body{height:100%;overflow:hidden}</style>
</head><body class="compose-page"></body></html>`,
        {
          headers: { "Content-Type": "text/html" },
        },
      );
    }
    const path = url.pathname.slice(1);
    return new Response(files.get(path) ?? "Not found", {
      status: files.has(path) ? 200 : 404,
      headers: {
        "Content-Type": path.endsWith(".svg") ? "image/svg+xml" : "text/css",
      },
    });
  },
});
const profile = await mkdtemp(join(tmpdir(), "wn-theme-render-"));
const outputDir = join(import.meta.dir, "../app/assets/themes");
try {
  await mkdir(outputDir, { recursive: true });
  for (const [theme, asset] of themes) {
    const output = join(outputDir, `${asset}.png`);
    const process = Bun.spawn(
      [
        "chromium",
        "--headless",
        "--hide-scrollbars",
        "--disable-gpu",
        `--user-data-dir=${profile}`,
        "--force-device-scale-factor=1",
        "--window-size=1280,800",
        "--virtual-time-budget=1000",
        `--screenshot=${output}`,
        `${server.url}?theme=${theme}`,
      ],
      { stdout: "ignore", stderr: "ignore" },
    );
    if ((await process.exited) !== 0) {
      throw new Error(`Chromium failed to render ${theme}`);
    }
    console.log(`${theme}: ${output}`);
  }
} finally {
  server.stop(true);
  await rm(profile, { recursive: true, force: true });
}
