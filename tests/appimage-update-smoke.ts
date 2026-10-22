#!/usr/bin/env bun
// Real signed AppImage boundary regressions. Usage:
// bun tests/appimage-update-smoke.ts /path/to/appimagetool build/wn-appimage-update
// Requires gpg, zsyncmake and mksquashfs; ephemeral signing keys never leave tmp.
import { spawn } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  copyFileSync,
  cpSync,
  chmodSync,
  rmSync,
  readdirSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { createHash } from "node:crypto";
import { createInterface } from "node:readline";

const sleep = Bun.sleep;
const digest = (path: string) =>
  createHash("sha256").update(readFileSync(path)).digest("hex");
function check(value: unknown, message: string): asserts value {
  if (!value) {
    throw new Error(message);
  }
}
function run(
  args: string[],
  env: Record<string, string | undefined> = process.env,
) {
  const result = Bun.spawnSync(args, { env, stdout: "pipe", stderr: "pipe" });
  check(
    result.exitCode === 0,
    `${args[0]} failed (${result.exitCode}): ${result.stdout}\n${result.stderr}`,
  );
  return result.stdout.toString();
}
type Spec = {
  source: string;
  helper: string;
  home: string;
  feed: string;
  original: string;
  expect: string;
  proxy: boolean;
  log: string;
  errors: string;
  result: string;
};
async function worker(path: string) {
  const spec: Spec = JSON.parse(readFileSync(path, "utf8"));
  const stage = mkdtempSync(join(dirname(spec.source), ".wn-update-"));
  const executable = join(stage, "wn-appimage-update");
  copyFileSync(spec.helper, executable);
  chmodSync(executable, 0o700);
  cpSync(
    join(dirname(spec.helper), "appimage-update-lib"),
    join(stage, "lib"),
    { recursive: true },
  );
  const env = {
    ...process.env,
    WN_TEST_UPDATE_FEED: spec.feed,
    LD_LIBRARY_PATH: join(stage, "lib"),
    APPIMAGE_EXTRACT_AND_RUN: "1",
    WN_APPIMAGE_TEST_LOG: spec.log,
    APPDIR: "/tmp/old-appimage-test-mount",
    APPIMAGE: spec.source,
    WN_SOCKS5_PROXY: spec.proxy ? "127.0.0.1:9" : "",
  };
  const child = spawn(
    executable,
    [
      spec.source,
      spec.home,
      "2026.10.2+9",
      spec.feed,
      String(process.pid),
      stage,
      "0",
    ],
    { env, detached: true, stdio: ["pipe", "pipe", "pipe"] },
  );
  let errors = "",
    armed = false;
  child.stderr.on("data", (data) => {
    errors += data.toString();
    writeFileSync(spec.errors, errors);
  });
  const lines: string[] = [];
  const kill = () => {
    try {
      process.kill(-child.pid!, "SIGKILL");
    } catch {}
  };
  const timeout = setTimeout(() => {
    kill();
    console.error(`helper timed out: ${lines}\n${errors}`);
    process.exit(1);
  }, 180000);
  try {
    for await (const line of createInterface({ input: child.stdout })) {
      lines.push(line);
      if (line.startsWith("R ")) {
        check(
          spec.expect === "ready" || spec.expect === "quiet",
          `unsafe image reached Ready: ${lines}`,
        );
        check(
          digest(spec.source) === spec.original,
          "source changed before apply",
        );
        child.stdin.write(spec.expect === "quiet" ? "Q" : "A");
      } else if (line === "X") {
        check(
          spec.expect === "ready" || spec.expect === "quiet",
          "unexpected apply ack",
        );
        await sleep(500);
        check(
          digest(spec.source) === spec.original,
          "replacement happened before parent exit",
        );
        check(!existsSync(spec.log), "relaunch happened before parent exit");
        writeFileSync(spec.result, JSON.stringify(lines));
        armed = true;
        child.unref();
        // Normal process exit, not SIGKILL: this is the exact parent pidfd.
        process.exit(0);
      } else if (line === "E") {
        check(spec.expect === "error", `update failed: ${lines}\n${errors}`);
        check(
          digest(spec.source) === spec.original,
          "rejected image changed source",
        );
        writeFileSync(spec.result, JSON.stringify(lines));
        return;
      } else if (line === "I" && spec.expect === "idle") {
        check(
          digest(spec.source) === spec.original,
          "up-to-date image changed source",
        );
        writeFileSync(spec.result, JSON.stringify(lines));
        return;
      }
      if (spec.expect === "interrupt" && line.startsWith("P")) {
        kill();
        check(
          digest(spec.source) === spec.original,
          "interruption changed source",
        );
        writeFileSync(spec.result, JSON.stringify(lines));
        return;
      }
    }
    throw new Error(`helper did not finish: ${lines}\n${errors}`);
  } finally {
    clearTimeout(timeout);
    if (!armed) {
      kill();
      rmSync(stage, { recursive: true, force: true });
    }
  }
}

async function main(tool: string, helper: string) {
  const root = mkdtempSync(join(tmpdir(), "wn-appimage-test-"));
  const feed = join(root, "feed");
  mkdirSync(feed);
  const gnupg = join(root, "gnupg");
  mkdirSync(gnupg, { mode: 0o700 });
  const env = {
    ...process.env,
    GNUPGHOME: gnupg,
    APPIMAGE_EXTRACT_AND_RUN: "1",
    APPIMAGELAUNCHER_DISABLE: "1",
    ARCH: process.arch === "arm64" ? "aarch64" : "x86_64",
  };
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const name = decodeURIComponent(new URL(request.url).pathname.slice(1));
      if (
        name.includes("/") ||
        name.includes("..") ||
        !existsSync(join(feed, name))
      ) {
        return new Response("missing", { status: 404 });
      }
      const bytes = readFileSync(join(feed, name)),
        header = request.headers.get("Range");
      if (!header) {
        return new Response(bytes, { headers: { "Accept-Ranges": "bytes" } });
      }
      const ranges = header
        .replace(/^bytes=/, "")
        .split(",")
        .map((value) => {
          const [first, last] = value.trim().split("-");
          return [
            Number(first),
            last ? Math.min(Number(last), bytes.length - 1) : bytes.length - 1,
          ];
        });
      if (ranges.length === 1) {
        const [start, end] = ranges[0];
        return new Response(bytes.subarray(start, end + 1), {
          status: 206,
          headers: {
            "Content-Range": `bytes ${start}-${end}/${bytes.length}`,
            "Accept-Ranges": "bytes",
          },
        });
      }
      const boundary = "wn-updater-regression-boundary";
      const parts: Buffer[] = [];
      for (const [start, end] of ranges) {
        parts.push(
          Buffer.from(
            `--${boundary}\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes ${start}-${end}/${bytes.length}\r\n\r\n`,
          ),
          bytes.subarray(start, end + 1),
          Buffer.from("\r\n"),
        );
      }
      parts.push(Buffer.from(`--${boundary}--\r\n`));
      return new Response(Buffer.concat(parts), {
        status: 206,
        headers: {
          "Content-Type": `multipart/byteranges; boundary=${boundary}`,
        },
      });
    },
  });
  try {
    for (const name of ["trusted", "different"]) {
      run(
        [
          "gpg",
          "--batch",
          "--pinentry-mode",
          "loopback",
          "--passphrase",
          "",
          "--quick-generate-key",
          `WN updater test ${name}`,
          "rsa2048",
          "sign",
          "1d",
        ],
        env,
      );
    }
    const keys = run(
      ["gpg", "--batch", "--with-colons", "--list-secret-keys"],
      env,
    )
      .split("\n")
      .filter((line) => line.startsWith("fpr:"))
      .map((line) => line.split(":")[9]);
    const url = `http://127.0.0.1:${server.port}`;
    function build(name: string, version: string, key?: string) {
      const appdir = join(root, `${name}.AppDir`);
      mkdirSync(appdir);
      writeFileSync(
        join(appdir, "AppRun"),
        `#!/bin/sh\nprintf '%s\\n' '${version}' "$1" "$APPIMAGE" "$LD_LIBRARY_PATH" > "$WN_APPIMAGE_TEST_LOG"\n`,
      );
      chmodSync(join(appdir, "AppRun"), 0o755);
      writeFileSync(
        join(appdir, "whitenoise.desktop"),
        `[Desktop Entry]\nType=Application\nName=White Noise\nExec=AppRun\nIcon=whitenoise-linux\nCategories=Utility;\nX-AppImage-Version=${version}\n`,
      );
      writeFileSync(
        join(appdir, "whitenoise-linux.svg"),
        '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="black"/></svg>',
      );
      const image = join(feed, `${name}.AppImage`);
      const args = [
        tool,
        "--no-appstream",
        "-u",
        `zsync|${url}/${name}.AppImage.zsync`,
      ];
      if (key) {
        args.push("--sign", "--sign-key", key);
      }
      run([...args, appdir, image], env);
      run(
        [
          "zsyncmake",
          "-u",
          `${url}/${name}.AppImage`,
          "-o",
          `${image}.zsync`,
          image,
        ],
        env,
      );
      return image;
    }
    const installed = build("installed", "2026.10.2+9", keys[0]);
    const newer = build("newer", "2026.10.2+10", keys[0]);
    const older = build("older", "2026.10.2+8", keys[0]);
    const unsigned = build("unsigned", "2026.10.2+11");
    const unsignedInstalled = build("unsigned-installed", "2026.10.2+9");
    const changed = build("changed", "2026.10.2+11", keys[1]);
    const bad = join(feed, "bad.AppImage");
    const corrupted = readFileSync(newer);
    corrupted[corrupted.length - 128] ^= 1;
    writeFileSync(bad, corrupted);
    run(
      ["zsyncmake", "-u", `${url}/bad.AppImage`, "-o", `${bad}.zsync`, bad],
      env,
    );
    const cases: [string, string, string, boolean][] = [
      ["unsigned-old", newer, "error", false],
      ["up-to-date", installed, "idle", false],
      ["unsigned", unsigned, "error", false],
      ["changed", changed, "error", false],
      ["older", older, "error", false],
      ["bad", bad, "error", false],
      ["proxy", newer, "error", true],
      ["interrupted", newer, "interrupt", false],
      ["quiet", newer, "quiet", false],
      ["success", newer, "ready", false],
    ];
    for (const [name, candidate, expect, proxy] of cases) {
      const directory = join(root, name);
      mkdirSync(directory);
      const baseline = name === "unsigned-old" ? unsignedInstalled : installed;
      const source = join(directory, "White Noise.AppImage");
      copyFileSync(baseline, source);
      chmodSync(source, 0o755);
      const home = join(directory, "custom data home");
      mkdirSync(home);
      const spec: Spec = {
        source,
        helper,
        home,
        feed: `${url}/${candidate.split("/").at(-1)}.zsync`,
        original: digest(source),
        expect,
        proxy,
        log: join(directory, "relaunch.log"),
        errors: join(directory, "helper-errors.log"),
        result: join(directory, "result.json"),
      };
      const specPath = join(directory, "spec.json");
      writeFileSync(specPath, JSON.stringify(spec));
      // Must remain asynchronous: the loopback HTTP server runs in this process.
      const child = Bun.spawn(
        [process.execPath, import.meta.path, "--worker", specPath],
        { stdout: "inherit", stderr: "inherit" },
      );
      check((await child.exited) === 0, `${name}: worker failed`);
      check(existsSync(spec.result), `${name}: no result`);
      if (expect === "ready" || expect === "quiet") {
        const deadline = Date.now() + 30000;
        while (digest(source) !== digest(newer) && Date.now() < deadline) {
          await sleep(100);
        }
        check(digest(source) === digest(newer), `${name}: update not applied`);
        const rollbacks = readdirSync(directory).filter((file) =>
          file.startsWith("White Noise.AppImage.rollback."),
        );
        check(
          rollbacks.length === 1 &&
            digest(join(directory, rollbacks[0])) === digest(installed),
          "rollback was not preserved",
        );
        check(statSync(source).mode & 0o111, "executable permission lost");
        if (expect === "ready") {
          while (!existsSync(spec.log) && Date.now() < deadline) {
            await sleep(100);
          }
          const lines = readFileSync(spec.log, "utf8").split("\n");
          check(
            JSON.stringify(lines) ===
              JSON.stringify(["2026.10.2+10", home, source, "", ""]),
            `bad relaunch argv/environment: ${lines}`,
          );
        } else {
          await sleep(500);
          check(!existsSync(spec.log), "normal quit relaunched application");
        }
      } else {
        check(digest(source) === digest(baseline), `${name}: source changed`);
        check(
          !readdirSync(directory).some((file) => file.includes(".rollback.")),
          `${name}: rejection created rollback`,
        );
      }
      console.log(`${name}: passed`);
    }
  } finally {
    server.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
}
if (process.argv[2] === "--worker") {
  await worker(process.argv[3]);
} else {
  check(
    process.argv.length === 4,
    "Usage: bun tests/appimage-update-smoke.ts APPIMAGETOOL HELPER",
  );
  await main(resolve(process.argv[2]), resolve(process.argv[3]));
}
