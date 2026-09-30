import { describe, expect, it } from "vitest";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  BUNDLE_ID,
  BUNDLE_NAME,
  DISPLAY_NAME,
  MIN_MACOS,
  PACKAGE_DIR,
  RESOURCE_BUNDLE,
  TRAY_ICON_FILES,
  infoPlist,
  parseArgs,
  resourceBundlePath,
  swiftBuildArgs,
  verifyTrayIcons,
} from "./native-bundle.mjs";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const README_PATH = path.join(ROOT, "README.md");
const MANIFEST_PATH = path.join(ROOT, "BBIconPackage", "Package.swift");
const TRAY_ICONS_SWIFT = path.join(ROOT, "BBIconPackage", "Sources", "BBIcon", "TrayIcons.swift");
const LOCATOR_SWIFT = path.join(ROOT, "BBIconPackage", "Sources", "BBIconCore", "ResourceBundleLocator.swift");

describe("the bundle's names", () => {
  it("are the ones the spec fixes", () => {
    // Display name, bundle directory, and bundle id are all different, and all
    // three are correct. The id is what the single-instance guard and the
    // login item key on, so changing it orphans every installed copy.
    expect(BUNDLE_NAME).toBe("BBIcon");
    expect(DISPLAY_NAME).toBe("bb Icon");
    expect(BUNDLE_ID).toBe("br.eng.gustavo.bb-menubar");
    expect(MIN_MACOS).toBe("14.0");
  });
});

describe("infoPlist", () => {
  it("declares the executable, id, and name the bundle is built with", () => {
    const plist = infoPlist({ version: "0.1.0" });
    expect(plist).toContain(`<key>CFBundleExecutable</key>\n\t<string>${BUNDLE_NAME}</string>`);
    expect(plist).toContain(`<key>CFBundleIdentifier</key>\n\t<string>${BUNDLE_ID}</string>`);
    expect(plist).toContain(`<key>CFBundleName</key>\n\t<string>${DISPLAY_NAME}</string>`);
    expect(plist).toContain(`<key>CFBundleDisplayName</key>\n\t<string>${DISPLAY_NAME}</string>`);
  });

  it("marks the app as an agent, so it has no Dock icon", () => {
    // Without this the menu bar app also owns a Dock icon it has no window for.
    expect(infoPlist({ version: "0.1.0" })).toContain("<key>LSUIElement</key>\n\t<true/>");
  });

  it("declares the macOS floor", () => {
    expect(infoPlist({ version: "0.1.0" })).toContain("<key>LSMinimumSystemVersion</key>\n\t<string>14.0</string>");
  });

  it("carries the version into both version keys", () => {
    const plist = infoPlist({ version: "1.2.3" });
    expect(plist).toContain("<key>CFBundleShortVersionString</key>\n\t<string>1.2.3</string>");
    expect(plist).toContain("<key>CFBundleVersion</key>\n\t<string>1.2.3</string>");
  });

  it("refuses a version that is not three numbers", () => {
    expect(() => infoPlist({ version: "v1.2" })).toThrow(/1\.2\.3/);
    // @ts-expect-error -- deliberately missing
    expect(() => infoPlist({})).toThrow(/1\.2\.3/);
  });
});

describe("swiftBuildArgs", () => {
  it("builds the app product for Apple Silicon in release", () => {
    // arm64 only, per the spec. Without --arch the build follows the host,
    // which under Rosetta is x86_64 and would ship a binary for the wrong Mac.
    const args = swiftBuildArgs();
    expect(args.slice(0, 3)).toEqual(["build", "-c", "release"]);
    expect(args).toContain("--arch");
    expect(args[args.indexOf("--arch") + 1]).toBe("arm64");
    expect(args[args.indexOf("--package-path") + 1]).toBe(PACKAGE_DIR);
    expect(args[args.indexOf("--product") + 1]).toBe(BUNDLE_NAME);
  });

  it("asks the same build configuration for its bin path", () => {
    // A bin path from a different --arch or -c is a different directory, and
    // the copy step would pick up a stale or missing binary.
    const build = swiftBuildArgs();
    const showBinPath = swiftBuildArgs({ showBinPath: true });
    expect(showBinPath).toContain("--show-bin-path");
    expect(showBinPath).not.toContain("--product");
    for (const flag of ["-c", "--arch", "--package-path"]) {
      expect(showBinPath[showBinPath.indexOf(flag) + 1]).toBe(build[build.indexOf(flag) + 1]);
    }
  });

  it("names the resource bundle SwiftPM emits for the app target", async () => {
    // SwiftPM names it `<package>_<target>.bundle`; the tray icons live in it
    // and the app's `ResourceBundleLocator` finds it by that name.
    const manifest = await readFile(MANIFEST_PATH, "utf8");
    const packageName = manifest.match(/name:\s*"([^"]+)"/)?.[1];
    expect(RESOURCE_BUNDLE).toBe(`${packageName}_${BUNDLE_NAME}.bundle`);
  });
});

describe("where the resource bundle goes", () => {
  it("is Contents/Resources, the first place the app looks", async () => {
    // `Bundle.module` is not used: swift-6.1's accessor looks beside the .app
    // and then at the absolute build path, and traps when neither exists.
    // The app's locator tries `Bundle.main.resourceURL` first instead.
    expect(resourceBundlePath("/x/BBIcon.app")).toBe(`/x/BBIcon.app/Contents/Resources/${RESOURCE_BUNDLE}`);
    const locator = await readFile(LOCATOR_SWIFT, "utf8");
    expect(locator).toMatch(/let directories = \[resourceURL,/);
    const trayIcons = await readFile(TRAY_ICONS_SWIFT, "utf8");
    expect(trayIcons).toContain(`resourceBundleName = "${RESOURCE_BUNDLE}"`);
    expect(trayIcons).toMatch(/resourceURL: main\.resourceURL/);
    expect(trayIcons).not.toMatch(/Bundle\.module\./);
  });

  it("needs every tray icon at 1x and 2x", () => {
    expect(TRAY_ICON_FILES).toContain("doneTemplate.png");
    expect(TRAY_ICON_FILES).toContain("doneTemplate@2x.png");
    expect(TRAY_ICON_FILES).toHaveLength(10);
  });
});

describe("verifyTrayIcons", () => {
  /** @param {(app: string) => Promise<void>} body */
  async function withApp(body) {
    const dir = await mkdtemp(path.join(os.tmpdir(), "bb-icon-bundle-"));
    try {
      await body(path.join(dir, "BBIcon.app"));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }

  /** @param {string} dir @param {string[]} files */
  async function writeIcons(dir, files) {
    await mkdir(dir, { recursive: true });
    for (const file of files) await writeFile(path.join(dir, file), "png");
  }

  it("finds every icon in the relocated bundle", () =>
    withApp(async (app) => {
      const dir = path.join(resourceBundlePath(app), "Contents", "Resources", "TrayIcons");
      await writeIcons(dir, TRAY_ICON_FILES);
      await expect(verifyTrayIcons(app)).resolves.toBe(dir);
    }));

  it("accepts a flat bundle too", () =>
    withApp(async (app) => {
      const dir = path.join(resourceBundlePath(app), "TrayIcons");
      await writeIcons(dir, TRAY_ICON_FILES);
      await expect(verifyTrayIcons(app)).resolves.toBe(dir);
    }));

  it("names a missing icon", () =>
    withApp(async (app) => {
      const dir = path.join(resourceBundlePath(app), "Contents", "Resources", "TrayIcons");
      await writeIcons(dir, TRAY_ICON_FILES.filter((file) => file !== "failedTemplate@2x.png"));
      await expect(verifyTrayIcons(app)).rejects.toThrow(/failedTemplate@2x\.png.*npm run icons/);
    }));

  it("refuses a bundle left beside the .app, where Resources does not have it", () =>
    withApp(async (app) => {
      await writeIcons(path.join(app, RESOURCE_BUNDLE, "Contents", "Resources", "TrayIcons"), TRAY_ICON_FILES);
      await expect(verifyTrayIcons(app)).rejects.toThrow(/no tray icons/);
    }));
});

describe("parseArgs", () => {
  it("reads flags with and without values", () => {
    const args = parseArgs(["--version", "0.1.0", "--skip-notarize"]);
    expect(args.get("version")).toBe("0.1.0");
    expect(args.get("skip-notarize")).toBe(true);
    expect(args.has("identity")).toBe(false);
  });

  it("records a flag given with no value as true, which the caller must refuse", () => {
    // `--identity ""` parses this way; signing with it would run
    // `codesign --sign true`, whose failure names neither the flag nor the
    // missing value.
    expect(parseArgs(["--identity", "--skip-notarize"]).get("identity")).toBe(true);
  });
});

describe("the bundle and the rest of the repo agree", () => {
  it("declares the same macOS floor as Package.swift", async () => {
    // Raising `platforms` alone would leave the binary above the floor the
    // plist and the README advertise, and the app refuses to launch on the
    // older macOS with every check green.
    const manifest = await readFile(MANIFEST_PATH, "utf8");
    const declared = manifest.match(/\.macOS\(\.v(\d+)\)/);
    expect(declared).not.toBeNull();
    expect(declared?.[1]).toBe(MIN_MACOS.split(".")[0]);
  });

  it("builds the package directory that exists", async () => {
    await expect(readFile(path.join(ROOT, PACKAGE_DIR, "Package.swift"), "utf8")).resolves.toContain("BBIcon");
  });

  it("is promised by the README", async () => {
    const readme = await readFile(README_PATH, "utf8");
    expect(readme).toContain(`macOS ${MIN_MACOS.split(".")[0]} or later`);
  });

  it("regenerates the icons before it packages", async () => {
    // The glyphs are gitignored, so a clean checkout that packaged without the
    // icon step would ship an app with no menu bar image.
    const pkg = JSON.parse(await readFile(path.join(ROOT, "package.json"), "utf8"));
    expect(pkg.scripts.dist).toMatch(/icons.*native-bundle\.mjs/);
    expect(pkg.version).toMatch(/^\d+\.\d+\.\d+$/);
  });
});
