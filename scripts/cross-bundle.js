#!/usr/bin/env bun
// Bundle the target loader's dependency closure without executing target code.
import { closeSync, cpSync, existsSync, mkdirSync, openSync, readSync, readdirSync, realpathSync } from "node:fs";
import { basename, dirname, extname, join, relative } from "node:path";

const [system, destination, ...roots] = Bun.argv.slice(2);
const libdir = join(destination, system === "linux" ? "usr/lib" : system === "darwin" ? "Contents/Frameworks" : ".");
// macOS packages build on a Mac; cross-toolchain.sh points these at Xcode's tools.
const objdump = process.env.WN_OBJDUMP ?? "objdump";
const installNameTool = process.env.WN_INSTALL_NAME_TOOL ?? "install_name_tool";
mkdirSync(libdir, { recursive: true });

function* files(root, symlinks = false) {
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) yield* files(path, symlinks);
    else if (entry.isFile() || (symlinks && entry.isSymbolicLink())) yield path;
  }
}

const index = new Map();
for (const root of roots) {
  if (!existsSync(root)) continue;
  for (const path of files(root, true)) {
    const name = basename(path);
    if (name.includes(".so") || name.endsWith(".dll") || name.endsWith(".dylib")) {
      const key = name.toLowerCase();
      if (!index.has(key)) index.set(key, path);
    }
  }
}

const windowsSystem = new Set("kernel32.dll bcryptprimitives.dll avicap32.dll user32.dll gdi32.dll advapi32.dll shell32.dll ole32.dll oleaut32.dll uuid.dll ws2_32.dll crypt32.dll bcrypt.dll ncrypt.dll secur32.dll iphlpapi.dll userenv.dll ntdll.dll shlwapi.dll comdlg32.dll winmm.dll version.dll setupapi.dll cfgmgr32.dll dwmapi.dll imm32.dll uxtheme.dll dinput8.dll dxgi.dll d3d11.dll d3d12.dll dxguid.dll opengl32.dll glu32.dll msvcrt.dll ucrtbase.dll winhttp.dll wldap32.dll normaliz.dll dnsapi.dll powrprof.dll winspool.drv propsys.dll avrt.dll hid.dll mf.dll mfplat.dll mfreadwrite.dll mfuuid.dll strmiids.dll ksuser.dll dcomp.dll shcore.dll msimg32.dll usp10.dll dbghelp.dll psapi.dll authz.dll netapi32.dll wintrust.dll imagehlp.dll wtsapi32.dll win32u.dll".split(" "));
const linuxSystem = /^(?:ld-linux-aarch64\.so\.1|lib(?:c|m|dl|pthread|rt|resolv|util)\.so\.[0-9]+)$/;

function kind(path) {
  const fd = openSync(path, "r");
  const magic = Buffer.alloc(4);
  let count;
  try { count = readSync(fd, magic, 0, 4, 0); }
  finally { closeSync(fd); }
  if (count >= 2 && magic[0] === 0x4d && magic[1] === 0x5a) return "windows";
  if (count !== 4) return null;
  const header = magic.readUInt32BE(0);
  if (header === 0x7f454c46) return "linux";
  if ([0xcffaedfe, 0xfeedfacf, 0xcafebabe].includes(header)) return "darwin";
  return null;
}

function run(command) {
  const result = Bun.spawnSync(command, { stdout: "pipe", stderr: "inherit" });
  if (result.exitCode !== 0) throw new Error(`${command[0]} failed (${result.exitCode}): ${command.slice(1).join(" ")}`);
  return result.stdout.toString();
}

function dependencies(path) {
  if (system === "linux") {
    return Array.from(run(["readelf", "-d", path]).matchAll(/\(NEEDED\).*\[(.*?)\]/g), match => match[1]);
  }
  if (system === "windows") {
    return Array.from(run(["x86_64-w64-mingw32-objdump", "-p", path]).matchAll(/DLL Name:\s+(\S+)/g), match => match[1]);
  }
  return run([objdump, "--macho", "--dylibs-used", path]).split("\n").slice(1)
    .filter(line => line.includes(" (")).map(line => line.trim().split(" (", 1)[0]);
}

const queue = Array.from(files(destination)).filter(path => kind(path) === system);
const seen = new Set();
while (queue.length) {
  const path = queue.pop();
  if (seen.has(path)) continue;
  seen.add(path);
  for (const dependency of dependencies(path)) {
    const name = basename(dependency);
    const lower = name.toLowerCase();
    if (system === "windows" && (windowsSystem.has(lower) || lower.startsWith("api-ms-") || lower.startsWith("ext-ms-"))) continue;
    if (system === "linux" && linuxSystem.test(name)) continue;
    if (system === "darwin" && (dependency.startsWith("/usr/lib/") || dependency.startsWith("/System/Library/"))) continue;
    const target = join(libdir, name);
    if (!existsSync(target)) {
      const source = index.get(lower);
      if (!source) throw new Error(`Unresolved ${system} runtime dependency: ${dependency} (required by ${path})`);
      if (kind(source) !== system) throw new Error(`Wrong target library: ${source}`);
      cpSync(realpathSync(source), target, { preserveTimestamps: true });
      queue.push(target);
    }
    if (system === "darwin") run([installNameTool, "-change", dependency, "@rpath/" + name, path]);
  }
  const libraryPath = relative(dirname(path), libdir) || ".";
  if (system === "linux") {
    run(["patchelf", "--set-rpath", "$ORIGIN/" + libraryPath, path]);
  } else if (system === "darwin") {
    run([installNameTool, "-add_rpath", "@loader_path/" + libraryPath, path]);
    if (extname(path) === ".dylib") run([installNameTool, "-id", "@rpath/" + basename(path), path]);
  }
}
console.log(`Bundled and checked ${seen.size} ${system} executables/libraries`);
