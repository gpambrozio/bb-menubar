// Builds the native BBIcon.app: a release build of the Swift package, then the
// bundle assembled around it. Signing and notarization are optional and off by
// default -- the spec defers them, along with the dmg and the Homebrew cask --
// so with no identity this writes an unsigned `release/native/BBIcon.app` and
// stops.
//
// Ported from Paseo Icon's packaging script. It is a script rather than a
// build-system plugin because the order matters and has to be visible: the
// bundle is complete before it is signed, and signed before it is notarized.
// A signature over a bundle that is still changing does not verify.
//
// The pure parts (the Info.plist, the build arguments, the flag parser) are
// exported and tested; the rest shells out and is exercised by running it.

import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { GLYPHS } from "./make-icons.mjs";

/** The bundle directory and executable name. Not the display name. */
export const BUNDLE_NAME = "BBIcon";
export const DISPLAY_NAME = "bb Icon";
export const BUNDLE_ID = "br.eng.gustavo.bb-menubar";
/**
 * The macOS floor. It is declared here, in Package.swift's `platforms`, and in
 * the README; the test holds all three together. Raising it means raising all
 * three.
 */
export const MIN_MACOS = "14.0";

/** The Swift package, relative to the repository root. */
export const PACKAGE_DIR = "BBIconPackage";
/** The resource bundle SwiftPM emits beside the executable: `<package>_<target>.bundle`. */
export const RESOURCE_BUNDLE = `${PACKAGE_DIR}_${BUNDLE_NAME}.bundle`;

/**
 * Where the app carries the resource bundle: `Contents/Resources`, the first
 * place the app's `ResourceBundleLocator` looks. Not `Bundle.module`, whose
 * swift-6.1 accessor looks beside the `.app` itself and then at the absolute
 * build path, and traps when neither exists -- as on any other Mac.
 *
 * @param {string} app
 */
export function resourceBundlePath(app) {
  return path.join(app, "Contents", "Resources", RESOURCE_BUNDLE);
}

/** Every tray icon file the app refuses to start without: 1x and 2x per glyph. */
export const TRAY_ICON_FILES = Object.keys(GLYPHS).flatMap((stem) => [`${stem}Template.png`, `${stem}Template@2x.png`]);

/** @param {string} p */
async function isDirectory(p) {
  try {
    return (await stat(p)).isDirectory();
  } catch {
    return false;
  }
}

/**
 * Checks, without launching the app, that the relocated resource bundle holds
 * every tray icon. SwiftPM lays a macOS resource bundle out with
 * `Contents/Resources`; `Bundle` reads a flat one too, so either is accepted.
 * Returns the directory the icons are in; throws naming what is missing.
 *
 * @param {string} app
 */
export async function verifyTrayIcons(app) {
  const bundle = resourceBundlePath(app);
  const candidates = [path.join(bundle, "Contents", "Resources", "TrayIcons"), path.join(bundle, "TrayIcons")];
  let dir;
  for (const candidate of candidates) {
    if (await isDirectory(candidate)) {
      dir = candidate;
      break;
    }
  }
  if (dir === undefined) {
    throw new Error(`The app has no tray icons: neither ${candidates.map((c) => path.relative(app, c)).join(" nor ")} exists.`);
  }
  const missing = [];
  for (const file of TRAY_ICON_FILES) {
    try {
      if (!(await stat(path.join(dir, file))).isFile()) missing.push(file);
    } catch {
      missing.push(file);
    }
  }
  if (missing.length > 0) {
    throw new Error(`The app is missing tray icons in ${path.relative(app, dir)}: ${missing.join(", ")}. Run \`npm run icons\` first (\`npm run dist\` does).`);
  }
  return dir;
}

/** notarytool takes credentials on argv, so nothing here echoes its command. */
const CREDENTIAL_ENV = ["APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID"];

/**
 * The bundle's Info.plist. `LSUIElement` is what keeps the app out of the
 * Dock; without it the menu bar app also owns a Dock icon it has no window
 * for.
 *
 * @param {{ version: string }} options
 */
export function infoPlist({ version }) {
  if (!/^\d+\.\d+\.\d+$/.test(version ?? "")) {
    throw new Error(`version must look like 1.2.3, got ${JSON.stringify(version)}`);
  }
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>en</string>
\t<key>CFBundleDisplayName</key>
\t<string>${DISPLAY_NAME}</string>
\t<key>CFBundleExecutable</key>
\t<string>${BUNDLE_NAME}</string>
\t<key>CFBundleIconFile</key>
\t<string>icon</string>
\t<key>CFBundleIdentifier</key>
\t<string>${BUNDLE_ID}</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>${DISPLAY_NAME}</string>
\t<key>CFBundlePackageType</key>
\t<string>APPL</string>
\t<key>CFBundleShortVersionString</key>
\t<string>${version}</string>
\t<key>CFBundleVersion</key>
\t<string>${version}</string>
\t<key>LSApplicationCategoryType</key>
\t<string>public.app-category.developer-tools</string>
\t<key>LSMinimumSystemVersion</key>
\t<string>${MIN_MACOS}</string>
\t<key>LSUIElement</key>
\t<true/>
\t<key>NSHighResolutionCapable</key>
\t<true/>
\t<key>NSHumanReadableCopyright</key>
\t<string>Copyright © 2026 Gustavo Ambrozio</string>
</dict>
</plist>
`;
}

/**
 * The `swift build` arguments. Releases are Apple Silicon only, so the arch is
 * stated rather than taken from the host -- under Rosetta the host is x86_64.
 * The bin-path query must repeat the same configuration and arch, or it names
 * a different build directory than the one just built.
 *
 * @param {{ showBinPath?: boolean }} [options]
 */
export function swiftBuildArgs({ showBinPath = false } = {}) {
  const common = ["build", "-c", "release", "--arch", "arm64", "--package-path", PACKAGE_DIR];
  return showBinPath ? [...common, "--show-bin-path"] : [...common, "--product", BUNDLE_NAME];
}

/**
 * `--flag value` pairs and bare `--flag`s. A flag with no value is recorded as
 * `true`, which is how `--identity ""` arrives; the caller refuses that.
 *
 * @param {string[]} argv
 * @returns {Map<string, string | true>}
 */
export function parseArgs(argv) {
  /** @type {Map<string, string | true>} */
  const args = new Map();
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === undefined || !flag.startsWith("--")) continue;
    const next = argv[i + 1];
    if (next !== undefined && next !== "" && !next.startsWith("--")) {
      args.set(flag.slice(2), next);
      i++;
    } else {
      args.set(flag.slice(2), true);
    }
  }
  return args;
}

/**
 * @param {string} command
 * @param {string[]} args
 * @param {import("node:child_process").SpawnOptions} [options]
 * @returns {Promise<{ code: number | null, stdout: string, stderr: string }>}
 */
function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk) => (stdout += chunk));
    child.stderr?.on("data", (chunk) => (stderr += chunk));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

/**
 * @param {string} command
 * @param {string[]} args
 * @param {string} what
 * @param {import("node:child_process").SpawnOptions} [options]
 */
async function runOrThrow(command, args, what, options) {
  const { code, stdout, stderr } = await run(command, args, options);
  // `args` may hold the app-specific password, so only the command is named.
  if (code !== 0) throw new Error(`${what} failed (${command} exited ${code})\n${stderr || stdout}`);
  return stdout;
}

function readCredentials() {
  const missing = CREDENTIAL_ENV.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    throw new Error(
      `Cannot notarize: ${missing.join(", ")} not set. APPLE_ID is the Apple ` +
        `account email, APPLE_APP_SPECIFIC_PASSWORD an app-specific password from ` +
        `appleid.apple.com, and APPLE_TEAM_ID the 10-character team from the ` +
        `signing certificate's common name. Pass --skip-notarize to sign only.`,
    );
  }
  return [
    "--apple-id", String(process.env.APPLE_ID),
    "--password", String(process.env.APPLE_APP_SPECIFIC_PASSWORD),
    "--team-id", String(process.env.APPLE_TEAM_ID),
  ];
}

/**
 * Renders the 1024px app icon (from `npm run icons`) into the .icns macOS
 * actually reads.
 *
 * @param {string} root
 * @param {string} resourcesDir
 */
async function buildIcns(root, resourcesDir) {
  const source = path.join(root, "assets", "generated", "icon.png");
  try {
    await readFile(source);
  } catch {
    throw new Error(`Missing ${path.relative(root, source)}. Run \`npm run icons\` first (\`npm run dist\` does).`);
  }
  const iconset = path.join(root, "release", "native", "icon.iconset");
  await rm(iconset, { recursive: true, force: true });
  await mkdir(iconset, { recursive: true });
  for (const size of [16, 32, 128, 256, 512]) {
    await runOrThrow("sips", ["-z", String(size), String(size), source, "--out", path.join(iconset, `icon_${size}x${size}.png`)], "Rendering icon");
    await runOrThrow("sips", ["-z", String(size * 2), String(size * 2), source, "--out", path.join(iconset, `icon_${size}x${size}@2x.png`)], "Rendering icon");
  }
  await runOrThrow("iconutil", ["-c", "icns", iconset, "-o", path.join(resourcesDir, "icon.icns")], "Building icns");
  await rm(iconset, { recursive: true, force: true });
}

/**
 * Builds, then assembles the bundle from the release build. The tray PNGs come
 * from the Swift package's own resource bundle, which `swift build` produces
 * beside the executable; it goes into `Contents/Resources` (see
 * `resourceBundlePath`), and is checked there before anything is signed.
 *
 * @param {{ root: string, version: string }} options
 */
export async function buildBundle({ root, version }) {
  // Checked here rather than only where the plist is written: that happens
  // after `swift build -c release`, so a typo in --version would burn the whole
  // release build before saying so.
  infoPlist({ version });

  await runOrThrow("swift", swiftBuildArgs(), "Building the app", { cwd: root });
  const binDir = (await runOrThrow("swift", swiftBuildArgs({ showBinPath: true }), "Locating the build", { cwd: root })).trim();

  const out = path.join(root, "release", "native");
  const app = path.join(out, `${BUNDLE_NAME}.app`);
  await rm(app, { recursive: true, force: true });
  const macos = path.join(app, "Contents", "MacOS");
  const resources = path.join(app, "Contents", "Resources");
  await mkdir(macos, { recursive: true });
  await mkdir(resources, { recursive: true });

  await runOrThrow("cp", [path.join(binDir, BUNDLE_NAME), path.join(macos, BUNDLE_NAME)], "Copying the executable");
  // The resource bundle SwiftPM emits for the app target, carrying the tray icons.
  await runOrThrow("cp", ["-R", path.join(binDir, RESOURCE_BUNDLE), path.dirname(resourceBundlePath(app))], "Copying resources");
  await verifyTrayIcons(app);
  await writeFile(path.join(app, "Contents", "Info.plist"), infoPlist({ version }));
  await writeFile(path.join(app, "Contents", "PkgInfo"), "APPL????");
  await buildIcns(root, resources);
  await runOrThrow("plutil", ["-lint", path.join(app, "Contents", "Info.plist")], "Validating Info.plist");
  return app;
}

/**
 * Signs with the hardened runtime and a secure timestamp, both of which
 * notarization requires. Deep, because the resource bundle is inside.
 *
 * @param {string} app
 * @param {string} identity
 */
export async function sign(app, identity) {
  await runOrThrow("codesign", ["--force", "--deep", "--options", "runtime", "--timestamp", "--sign", identity, app], "Signing");
  await runOrThrow("codesign", ["--verify", "--strict", "--deep", app], "Verifying the signature");
}

/**
 * Submits, waits, and staples. Apple accepting the submission is not the same
 * as the ticket being attached, so both are read back off the finished bundle.
 *
 * @param {string} app
 * @param {string} out
 */
export async function notarize(app, out) {
  const credentials = readCredentials();
  const zip = path.join(out, "notarize.zip");
  // Scratch, not an artifact: removed whether Apple accepted or refused.
  try {
    await runOrThrow("ditto", ["-c", "-k", "--keepParent", app, zip], "Zipping for notarization");
    console.log(`submitting ${path.basename(app)} to Apple; this waits on their queue`);
    const output = await runOrThrow("xcrun", ["notarytool", "submit", zip, ...credentials, "--wait"], "Notarizing");
    // notarytool exits 0 for a submission that finished but was rejected, so the
    // status line is what actually decides.
    if (!/status:\s*Accepted/i.test(output)) throw new Error(`Apple did not accept ${path.basename(app)}:\n${output}`);
    await runOrThrow("xcrun", ["stapler", "staple", app], "Stapling");
    await runOrThrow("xcrun", ["stapler", "validate", app], "Validating the staple");
    await runOrThrow("spctl", ["-a", "-t", "exec", "-vv", app], "Gatekeeper assessment");
  } finally {
    await rm(zip, { force: true });
  }
}

// Usage: node scripts/native-bundle.mjs [--version 0.1.0] [--identity "Developer ID Application: ..."] [--skip-notarize]
//
// `import.meta.url` is realpath-resolved and percent-encoded; `process.argv[1]`
// is neither. Comparing them directly makes this block a silent no-op for a
// clone reached through a symlink or a path with a space -- the script runs,
// does nothing, and exits 0. `realpathSync` throws for a path that does not
// exist (`node -e "..." some-arg` sets argv[1] to that positional), so a
// failure there falls back to the raw string rather than dying at import.
/** @param {string} p */
const mainPath = (p) => {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
};

if (process.argv[1] && fileURLToPath(import.meta.url) === mainPath(process.argv[1])) {
  const args = parseArgs(process.argv.slice(2));
  const root = process.cwd();

  const versionArg = args.get("version");
  if (versionArg === true) throw new Error("--version was given with no value; pass 1.2.3 or leave the flag out");
  const version = versionArg ?? JSON.parse(await readFile(path.join(root, "package.json"), "utf8")).version;

  const app = await buildBundle({ root, version });
  console.log(`built ${app}`);

  const identity = args.get("identity") ?? process.env.CODESIGN_IDENTITY;
  // `--identity ""` parses as the flag with no value. Signing with that reaches
  // `codesign --sign true`, whose failure names neither the flag nor the value.
  if (identity === true) {
    throw new Error("--identity was given with no value; pass the certificate's common name or leave the flag out");
  }
  if (!identity) {
    // Unsigned is a legitimate local build; shipping one is not, so it says so.
    console.log("no --identity and no CODESIGN_IDENTITY: leaving the bundle unsigned, which is fine locally and never shippable");
    process.exit(0);
  }
  await sign(app, identity);
  console.log("signed");

  if (args.get("skip-notarize")) {
    console.log("--skip-notarize: stopping before Apple");
    process.exit(0);
  }
  await notarize(app, path.join(root, "release", "native"));
  console.log("notarized and stapled");
}
