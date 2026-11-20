import { once } from "node:events";
import { chmod, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { createInterface } from "node:readline";
import { Readable } from "node:stream";
import { join } from "node:path";

const home = "/var/lib/wn-ngit-boat";
const install = "/opt/wn-ngit";
const socketPath = "/run/wn-ngit-boat/adapter.sock";
const jobs = join(home, "jobs");
const snapshot = "wn-ngit-native-06cbe039-pax";
const limit = 4;
const ttl = 5700;
const jobId = /^[a-f0-9]{64}$/;
const sandboxId = /^bx_[a-z0-9]+$/;
const metadata = {
  GITHUB_SHA: true,
  GITHUB_REF: true,
  NGIT_CI_REPOSITORY: true,
  NGIT_CI_TRIGGER_EVENT: true,
};
let active = 0;

function boat(args: string[], signal: AbortSignal) {
  return Bun.spawn([join(install, "boat"), "--no-update", "--json", ...args], {
    signal,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore",
  });
}

async function deleteVM(id: string) {
  const deletion = boat(["delete", id, "--yes"], AbortSignal.timeout(30_000));
  const response = await new Response(deletion.stdout).json();
  if ((await deletion.exited) !== 0 && response.status !== 404) {
    throw new Error(
      `Boat could not delete ${id}: ${response.code ?? response.status}`,
    );
  }
  for (let attempt = 0; attempt < 10; attempt++) {
    const info = boat(["info", id], AbortSignal.timeout(5_000));
    const state = await new Response(info.stdout).json();
    await info.exited;
    if (state.status === 404) {
      await rm(join(jobs, id), { force: true });
      return;
    }
    await Bun.sleep(1_000);
  }
  throw new Error(`Boat deletion of ${id} is unconfirmed`);
}

async function waitHydrated(id: string, signal: AbortSignal) {
  const until = Date.now() + 240_000;
  while (Date.now() < until) {
    const info = boat(
      ["info", id],
      AbortSignal.any([signal, AbortSignal.timeout(15_000)]),
    );
    const response = await new Response(info.stdout).json();
    if ((await info.exited) !== 0) {
      throw new Error(
        `Boat info failed for ${id}: ${response.code ?? response.status}`,
      );
    }
    if (response.sandbox.hydrated) {
      return;
    }
    if (response.sandbox.state === "error") {
      throw new Error(`Boat restore failed for ${id}`);
    }
    await Bun.sleep(3_000);
    signal.throwIfAborted();
  }
  throw new Error(`Boat restore timed out for ${id}`);
}

async function send(socket: Socket, signal: AbortSignal, message: object) {
  if (!socket.destroyed && !socket.write(`${JSON.stringify(message)}\n`)) {
    await once(socket, "drain", { signal });
  }
}

async function serve(socket: Socket) {
  const abort = new AbortController();
  socket.on("error", () => abort.abort());
  socket.on("close", () => abort.abort());
  let id: string | undefined;
  let script: string | undefined;
  let acquired = false;
  let terminal: object;
  const started = performance.now();
  try {
    const chunks: Buffer[] = [];
    let bytes = 0;
    for await (const chunk of socket.iterator({ destroyOnReturn: false })) {
      const end = chunk.indexOf(10);
      const part = end === -1 ? chunk : chunk.subarray(0, end);
      bytes += part.length;
      if (bytes > 240 * 1024) {
        throw new Error("Boat execute request exceeds 240 KiB");
      }
      chunks.push(part);
      if (end !== -1) {
        break;
      }
    }
    const req = JSON.parse(Buffer.concat(chunks, bytes).toString("utf8"));
    socket.resume();
    if (
      req.type !== "execute" ||
      typeof req.identifier !== "string" ||
      !jobId.test(req.identifier) ||
      req.cmd !== "bash" ||
      !Array.isArray(req.args) ||
      req.args.length !== 1 ||
      req.args[0] !== "-s" ||
      typeof req.stdin !== "string" ||
      !req.env ||
      (req.artifact_dir != null &&
        req.artifact_dir !== `/tmp/ngit-ci-job-${req.identifier}/artifacts`)
    ) {
      throw new Error("Unsupported Boat execute request");
    }
    if (active === limit) {
      throw new Error("Boat workers are busy");
    }
    active++;
    acquired = true;
    const env: string[] = [];
    for (const [key, value] of Object.entries(req.env)) {
      if (
        !Object.hasOwn(metadata, key) ||
        typeof value !== "string" ||
        value.includes("\0")
      ) {
        throw new Error(`Unexpected Boat job environment key: ${key}`);
      }
      env.push(`${key}=${value}`);
    }
    abort.signal.throwIfAborted();
    script = join(home, `${crypto.randomUUID()}.sh`);
    await writeFile(script, req.stdin, { mode: 0o600, flag: "wx" });
    const create = boat(
      [
        "new",
        "--type",
        "large",
        "--from",
        snapshot,
        "--ttl",
        String(ttl),
        "--no-env",
        "--no-snapshots",
        "--name",
        `wn-ngit-${req.identifier.slice(0, 16)}`,
        "--file",
        `wn-job.sh=${script}`,
        "--file",
        `wn-guest.sh=${install}/boat-guest.sh`,
        "--file",
        `wn-act.sh=${install}/boat-act.sh`,
      ],
      AbortSignal.timeout(180_000),
    );
    let ready = false;
    let createError: string | undefined;
    for await (const line of createInterface({
      input: Readable.fromWeb(create.stdout),
    })) {
      const frame = JSON.parse(line);
      if (!id && typeof frame.id === "string" && sandboxId.test(frame.id)) {
        id = frame.id;
        await writeFile(join(jobs, id), "", { mode: 0o600 });
      }
      if (frame.event === "ready") {
        ready = true;
      }
      if (frame.event === "error") {
        createError = frame.code ?? frame.error;
      }
    }
    if ((await create.exited) !== 0 || !id || !ready) {
      throw new Error(
        `Boat VM did not start: ${createError ?? "missing ready response"}`,
      );
    }
    await send(socket, abort.signal, { type: "started" });
    await send(socket, abort.signal, {
      type: "stdout",
      data: `Boat VM ${id} ready\n`,
    });
    await waitHydrated(id, abort.signal);
    const exec = boat(
      [
        "exec",
        id,
        "--stream",
        "--timeout",
        "5200",
        "--",
        "sudo",
        "-n",
        "env",
        "-i",
        "HOME=/root",
        ...env,
        "bash",
        "/home/user/wn-guest.sh",
        req.artifact_dir ?? "",
      ],
      abort.signal,
    );
    let exit: number | undefined;
    for await (const line of createInterface({
      input: Readable.fromWeb(exec.stdout),
    })) {
      const frame = JSON.parse(line);
      if (
        (frame.type === "stdout" || frame.type === "stderr") &&
        typeof frame.data === "string"
      ) {
        await send(socket, abort.signal, {
          type: frame.type,
          data: frame.data,
        });
      } else if (frame.type === "exit" && Number.isInteger(frame.exitCode)) {
        exit = frame.exitCode;
      }
    }
    const status = await exec.exited;
    if (exit === undefined || status !== exit) {
      throw new Error(`Boat lost the exit status for ${id}`);
    }
    terminal = {
      type: "completed",
      exitCode: exit,
      duration: Math.floor((performance.now() - started) / 1000),
    };
  } catch (error) {
    terminal = { type: "error", error: String(error) };
  } finally {
    if (id) {
      try {
        await deleteVM(id);
      } catch (error) {
        console.error(error);
        terminal = { type: "error", error: String(error) };
        acquired = false;
      }
    }
    if (script) {
      await rm(script, { force: true });
    }
    if (acquired) {
      active--;
    }
  }
  await send(socket, abort.signal, terminal);
  socket.end();
}

await mkdir(jobs, { recursive: true, mode: 0o700 });
for (const id of await readdir(jobs)) {
  if (sandboxId.test(id)) {
    await deleteVM(id);
  }
}
await rm(socketPath, { force: true });
const server = createServer((socket) => {
  void serve(socket).catch((error) => {
    console.error(error);
    socket.destroy();
  });
});
server.listen(socketPath);
await once(server, "listening");
await chmod(socketPath, 0o660);
process.once("SIGTERM", () => server.close());
