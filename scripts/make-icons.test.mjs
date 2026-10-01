import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

import { GLYPHS, makeIcons } from "./make-icons.mjs";

const REPO_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const TRAY_VIEW_MODEL = path.join(REPO_ROOT, "BBIconPackage", "Sources", "BBIconCore", "Tray", "TrayViewModel.swift");

const STEMS = ["needsInput", "failed", "readyToReview", "working", "done"];
const OUTPUT_DIRS = [
  ["assets", "generated"],
  ["BBIconPackage", "Sources", "BBIcon", "Resources", "TrayIcons"],
];

describe("GLYPHS", () => {
  it("maps each bucket to the glyph the spec's table names, in section order", () => {
    expect(Object.entries(GLYPHS)).toEqual([
      ["needsInput", "megaphone"],
      ["failed", "circle-x"],
      ["readyToReview", "triangle-alert"],
      ["working", "loader-pinwheel"],
      ["done", "bb-logo"],
    ]);
  });

  it("uses the file stems the Swift tray loads by name", async () => {
    // TrayIcons.swift asks the bundle for `iconNames[bucket] + "Template"`. A
    // stem that drifts from that table ships a menu bar item with no image,
    // and nothing fails until a human looks at the menu bar.
    const swift = await readFile(TRAY_VIEW_MODEL, "utf8");
    const table = swift.match(/iconNames:[^=]*=\s*\[([^\]]*)\]/);
    expect(table, "iconNames table not found in TrayViewModel.swift").not.toBeNull();
    const names = [...(table?.[1] ?? "").matchAll(/\.\w+:\s*"(\w+)"/g)].map((m) => m[1]);
    expect(names).toEqual(Object.keys(GLYPHS));
  });
});

describe("makeIcons", () => {
  /** @type {string} */
  let root;

  beforeAll(async () => {
    root = await mkdtemp(path.join(os.tmpdir(), "make-icons-"));
    await makeIcons({ root, log: () => {} });
  });

  afterAll(async () => {
    await rm(root, { recursive: true, force: true });
  });

  for (const dir of OUTPUT_DIRS) {
    for (const stem of STEMS) {
      it(`writes ${stem} at 16px and 32px into ${dir.join("/")}`, async () => {
        const oneX = await sharp(path.join(root, ...dir, `${stem}Template.png`)).metadata();
        const twoX = await sharp(path.join(root, ...dir, `${stem}Template@2x.png`)).metadata();
        expect([oneX.width, oneX.height]).toEqual([16, 16]);
        expect([twoX.width, twoX.height]).toEqual([32, 32]);
      });
    }
  }

  it("writes the 1024px app icon to assets/generated only", async () => {
    const icon = await sharp(path.join(root, "assets", "generated", "icon.png")).metadata();
    expect([icon.width, icon.height]).toEqual([1024, 1024]);
    // The app icon is build input for the .icns, not a tray resource.
    await expect(access(path.join(root, ...OUTPUT_DIRS[1], "icon.png"))).rejects.toThrow();
  });
});
