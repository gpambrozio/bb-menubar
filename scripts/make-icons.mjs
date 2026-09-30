import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import sharp from "sharp";

// Inputs are read from this checkout; outputs go under `root`, which the test
// points at a temporary directory so it never touches the working tree.
const REPO_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const LUCIDE_ICONS_DIR = path.join(REPO_ROOT, "node_modules", "lucide-static", "icons");

// The bb mark, vendored unmodified from the bb desktop app 0.44.0:
//   /Applications/bb.app/Contents/Resources/app.asar.unpacked/node_modules/bb-app/app/dist/assets/bb-logo-BA9hTSLL.svg
// The hash in the name changes with every bb build; take the newest
// `bb-logo-*.svg` there when re-vendoring, and keep it a plain copy -- every
// correction below is applied here, never to the file.
const BB_LOGO_PATH = path.join(REPO_ROOT, "assets", "bb-logo.svg");

/** @param {string} root */
function outputDirs(root) {
  return {
    generated: path.join(root, "assets", "generated"),
    // The native app loads the tray glyphs through `Bundle.module`, so they
    // have to live inside the Swift target rather than beside it. Written here
    // rather than copied by a build step, so `swift run` and a packaged build
    // see the same files and neither can go stale against the other.
    trayIcons: path.join(root, "BBIconPackage", "Sources", "BBIcon", "Resources", "TrayIcons"),
  };
}

// One entry per thread bucket, in the tray's section order (the spec's "Say
// what Paseo Icon says" table). Each key is the on-disk file stem and must
// equal `TrayViewModelBuilder.iconNames` in BBIconCore; the test holds the two
// together. Each value is a lucide-static icon name, except `bb-logo`: the
// resting state shows bb's own mark rather than a thread glyph, as Paseo Icon
// does with the Paseo mark.
export const GLYPHS = {
  needsInput: "megaphone",
  failed: "circle-x",
  readyToReview: "triangle-alert",
  working: "loader-pinwheel",
  done: "bb-logo",
};
const BB_MARK_GLYPH = "bb-logo";

// Lucide's 24x24 artboard with the default stroke-width="2" reads thin and
// weedy at a 16px menu-bar size, next to native items drawn with heavier
// strokes. Judged against the vendored default at both 16px and 32px, this
// reads clearly without the pinwheel's inner strokes starting to touch at
// 2x. Rasterizing straight from the source and upscaling afterward would
// blur rather than fix this, so the stroke goes into the markup before sharp
// ever sees it. (Carried over from Paseo Icon unchanged.)
const LUCIDE_STROKE_WIDTH = 2.75;

// The template image is the mark's silhouette -- the `#mark` path, filled --
// on a square canvas centred on the logo's own viewBox, so the wide mark is
// letterboxed top and bottom rather than squeezed.
//
// Unlike the Paseo mark, the bb mark needs no correction. Measured as
// alpha-weighted ink coverage of the shipped 16px and 32px renders, against
// the Lucide set at stroke 2.75 (extent is the opaque bounding box):
//
//   megaphone        37% ink   88% x 94% of the canvas
//   circle-x         39% ink  100% x 100%
//   triangle-alert   33% ink  100% x 88%
//   loader-pinwheel  57% ink  100% x 100%
//   bb, 1.0 / 0      38% ink  100% x 88% (16px), 100% x 81% (32px)
//
// so straight from source it already sits between megaphone and circle-x on
// both counts. It cannot usefully grow: the mark spans 491 of the viewBox's
// 507 units, so it is width-bound and a larger scale clips its sides. A stroke
// of 8 (in viewBox units; it dilates the filled path) reaches 42% ink, and at
// 16 the b's counters visibly shrink at 16px -- heavier, and less like the logo.
// Both knobs are kept so a re-vendored mark can be retuned the same way.
const BB_MARK_SCALE = 1;
const BB_MARK_STROKE = 0;

// The app icon -- the Finder, dmg-window, and About-panel face of the app, not
// the tray image. native-bundle.mjs turns this single PNG into the .icns with
// sips and iconutil; 1024 is the largest slot macOS asks for, so rendering
// that one size and letting it downsample beats hand-keeping an iconset.
const APP_ICON_SIZE = 1024;

// The tile and mark match bb's own app icon, measured off the 1024px slot of
// /Applications/bb.app/Contents/Resources/icon.icns (bb 0.44.0): a white tile
// 848 px wide (82.8% of the canvas) whose outline is a superellipse of
// exponent 4 -- its edge sits 87 px in at 50 px down and 20 px in at 150 px
// down, which a circular corner cannot do -- with the full-colour mark 567 px
// wide (55.4%), centred. The two apps sit next to each other in the Finder,
// so the icon is matched to bb's rather than to Paseo Icon's black tile, which
// the graphite mark would disappear into.
const APP_TILE_FRACTION = 0.8281;
const APP_TILE_EXPONENT = 4;
const APP_TILE_FILL = "#ffffff";
const APP_MARK_FRACTION = 0.554;

// The notification badge, which is the whole visual difference between this
// icon and bb's: same tile, same mark, plus the dot that says "indicator".
// Every number is a fraction of the canvas so the badge survives being
// downsampled to the 16px slot with the rest of the icon.
//
// The ring is not decoration. The badge is deliberately large enough to
// overhang the tile's bottom-right corner, which puts part of the red on white
// and part of it on whatever is behind the icon; without a ring the
// overhanging arc disappears against a red-ish wallpaper or a Finder selection
// highlight.
const BADGE_RADIUS_FRACTION = 0.125;
const BADGE_RING_FRACTION = 0.022;
const BADGE_MARGIN_FRACTION = 0.008;
const BADGE_FILL = { r: 0xff, g: 0x3b, b: 0x30 }; // Apple's system red.
const BADGE_RING_COLOR = "#ffffff";

const TRANSPARENT = { r: 0, g: 0, b: 0, alpha: 0 };

/** @param {string} name */
async function lucideMarkup(name) {
  const raw = await readFile(path.join(LUCIDE_ICONS_DIR, `${name}.svg`), "utf8");
  // `stroke="currentColor"` never resolves when sharp rasterizes a standalone
  // SVG with no surrounding CSS `color` -- it renders empty rather than
  // erroring, so a missed substitution here is a silent blank icon.
  return raw
    .replaceAll('stroke="currentColor"', 'stroke="#000"')
    .replaceAll('stroke-width="2"', `stroke-width="${LUCIDE_STROKE_WIDTH}"`);
}

/**
 * The parts of the vendored logo the generator depends on. A re-vendored file
 * that is shaped differently fails here, by name, rather than rendering a
 * blank or distorted glyph.
 */
async function readBBLogo() {
  const raw = await readFile(BB_LOGO_PATH, "utf8");
  const viewBox = raw.match(/<svg\b[^>]*\sviewBox="([^"]+)"/)?.[1]?.trim().split(/[\s,]+/).map(Number);
  if (!viewBox || viewBox.length !== 4 || viewBox.some((n) => !Number.isFinite(n))) {
    throw new Error(`Expected a four-number viewBox on the <svg> in ${BB_LOGO_PATH}`);
  }
  const markPath = raw.match(/<path\b[^>]*\sid="mark"[^>]*\sd="([^"]+)"/)?.[1];
  if (!markPath) {
    // The silhouette is this one path; the rest of the file is shading
    // clipped to it. Without it there is nothing to rasterize as a template.
    throw new Error(`Expected a <path id="mark" d="..."> in ${BB_LOGO_PATH}`);
  }
  const [x, y, width, height] = /** @type {[number, number, number, number]} */ (viewBox);
  return { raw, viewBox: { x, y, width, height }, markPath };
}

async function bbMarkMarkup() {
  const { viewBox, markPath } = await readBBLogo();
  const cx = viewBox.x + viewBox.width / 2;
  const cy = viewBox.y + viewBox.height / 2;
  const side = Math.max(viewBox.width, viewBox.height);
  // Template images use only the alpha channel, so the fill colour is
  // cosmetic, but a concrete black is conventional and keeps the source
  // readable outside the tray. The stroke matches the fill so it fattens the
  // shape rather than outlining it. The mark's counters are holes cut by the
  // even-odd rule, so the rule has to come with the path.
  //
  // Declared at 24px, Lucide's size, so both kinds of glyph go through the
  // same render density below.
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"` +
    ` viewBox="${cx - side / 2} ${cy - side / 2} ${side} ${side}">` +
    `<g transform="translate(${cx},${cy}) scale(${BB_MARK_SCALE}) translate(${-cx},${-cy})">` +
    `<path d="${markPath}" fill-rule="evenodd" fill="#000"` +
    ` stroke="#000" stroke-width="${BB_MARK_STROKE}" stroke-linejoin="round"/>` +
    `</g></svg>`
  );
}

/** @param {string} glyph */
async function markupFor(glyph) {
  return glyph === BB_MARK_GLYPH ? bbMarkMarkup() : lucideMarkup(glyph);
}

/**
 * sharp happily writes a fully transparent PNG with no warning, and the tray
 * then shows nothing at all. Fail the build instead of shipping one.
 *
 * @param {Buffer} buffer
 * @param {string} file
 */
async function assertNotBlank(buffer, file) {
  const { data } = await sharp(buffer).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let i = 3; i < data.length; i += 4) {
    if ((data[i] ?? 0) > 0) return;
  }
  throw new Error(`Rasterized icon has no opaque pixels: ${file}`);
}

/** @param {{ r: number, g: number, b: number }} colour */
function cssColor({ r, g, b }) {
  return `rgb(${r},${g},${b})`;
}

/**
 * The superellipse |x|^n + |y|^n = 1, scaled to a `size` square. Sampled
 * finely enough that the polygon's facets are far below a pixel at 1024.
 *
 * @param {number} size
 */
function tileMarkup(size) {
  const half = size / 2;
  const STEPS = 720;
  const points = [];
  for (let i = 0; i < STEPS; i++) {
    const t = (2 * Math.PI * i) / STEPS;
    const cos = Math.cos(t);
    const sin = Math.sin(t);
    const x = half + half * Math.sign(cos) * Math.abs(cos) ** (2 / APP_TILE_EXPONENT);
    const y = half + half * Math.sign(sin) * Math.abs(sin) ** (2 / APP_TILE_EXPONENT);
    points.push(`${x.toFixed(2)},${y.toFixed(2)}`);
  }
  return Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">` +
      `<polygon points="${points.join(" ")}" fill="${APP_TILE_FILL}"/>` +
      `</svg>`,
  );
}

/**
 * The full-colour logo, trimmed to its ink and scaled to `width`. The logo is
 * declared only by its viewBox, so its intrinsic size is the viewBox's in
 * pixels; the density puts it at canvas width before the trim, so it is
 * rasterized once at full resolution and only ever scaled down.
 *
 * @param {number} canvas
 * @param {number} width
 */
async function renderMark(canvas, width) {
  const { raw, viewBox } = await readBBLogo();
  const trimmed = await sharp(Buffer.from(raw), { density: (72 * canvas) / viewBox.width })
    .trim()
    .png()
    .toBuffer();
  return sharp(trimmed).resize({ width }).png().toBuffer({ resolveWithObject: true });
}

/** @param {number} size */
function badgeMarkup(size) {
  const radius = size * BADGE_RADIUS_FRACTION;
  const ring = size * BADGE_RING_FRACTION;
  // The stroke straddles the path, so half of it sits outside `radius`. Anchor
  // on that outer edge or the ring is what gets clipped by the canvas.
  const centre = size - size * BADGE_MARGIN_FRACTION - (radius + ring / 2);
  return Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">` +
      `<circle cx="${centre}" cy="${centre}" r="${radius}"` +
      ` fill="${cssColor(BADGE_FILL)}" stroke="${BADGE_RING_COLOR}" stroke-width="${ring}"/>` +
      `</svg>`,
  );
}

/**
 * @param {Buffer} buffer
 * @param {number} x
 * @param {number} y
 */
async function pixelAt(buffer, x, y) {
  const { data } = await sharp(buffer)
    .extract({ left: Math.round(x), top: Math.round(y), width: 1, height: 1 })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  return { r: data[0] ?? 0, g: data[1] ?? 0, b: data[2] ?? 0 };
}

/**
 * `assertNotBlank` would pass on the tile alone, so a composite that silently
 * dropped an overlay -- a mistyped offset, an SVG sharp declined to parse --
 * would ship a plain white tile, or bb's own icon. Read the pixels back.
 *
 * @param {Buffer} buffer
 * @param {number} size
 */
async function assertOverlaysPainted(buffer, size) {
  const radius = size * BADGE_RADIUS_FRACTION;
  const ring = size * BADGE_RING_FRACTION;
  const badgeCentre = size - size * BADGE_MARGIN_FRACTION - (radius + ring / 2);
  const badge = await pixelAt(buffer, badgeCentre, badgeCentre);
  const TOLERANCE = 8;
  const badgeMatches =
    Math.abs(badge.r - BADGE_FILL.r) <= TOLERANCE &&
    Math.abs(badge.g - BADGE_FILL.g) <= TOLERANCE &&
    Math.abs(badge.b - BADGE_FILL.b) <= TOLERANCE;
  if (!badgeMatches) {
    throw new Error(
      `Badge centre is ${cssColor(badge)}, expected ${cssColor(BADGE_FILL)} -- the badge did not land`,
    );
  }
  // The canvas centre falls on the stroke where the two b's meet, which is
  // graphite in the logo and white if the mark is missing.
  const mark = await pixelAt(buffer, size / 2, size / 2);
  if (mark.r > 128 || mark.g > 128 || mark.b > 128) {
    throw new Error(`Icon centre is ${cssColor(mark)}, expected the graphite mark -- the mark did not land`);
  }
}

/**
 * @param {string} outDir
 * @param {(message: string) => void} log
 */
async function writeAppIcon(outDir, log) {
  const size = APP_ICON_SIZE;
  const tile = Math.round(size * APP_TILE_FRACTION);
  const inset = Math.round((size - tile) / 2);
  const mark = await renderMark(size, Math.round(size * APP_MARK_FRACTION));
  const buffer = await sharp({ create: { width: size, height: size, channels: 4, background: TRANSPARENT } })
    .composite([
      // Centre the tile; the badge then reaches into the transparent margin.
      { input: tileMarkup(tile), left: inset, top: inset },
      {
        input: mark.data,
        left: Math.round((size - mark.info.width) / 2),
        top: Math.round((size - mark.info.height) / 2),
      },
      { input: badgeMarkup(size), left: 0, top: 0 },
    ])
    .png()
    .toBuffer();
  const outFile = path.join(outDir, "icon.png");
  await assertNotBlank(buffer, outFile);
  await assertOverlaysPainted(buffer, size);
  await writeFile(outFile, buffer);
  log(`wrote ${outFile}`);
}

/**
 * Writes the ten tray glyphs into both output directories and the app icon
 * into `assets/generated`.
 *
 * @param {{ root?: string, log?: (message: string) => void }} [options]
 */
export async function makeIcons({ root = REPO_ROOT, log = console.log } = {}) {
  const { generated, trayIcons } = outputDirs(root);
  await mkdir(generated, { recursive: true });
  await mkdir(trayIcons, { recursive: true });

  for (const [stem, glyph] of Object.entries(GLYPHS)) {
    const svg = await markupFor(glyph);
    for (const scale of [1, 2]) {
      const size = 16 * scale;
      const file = `${stem}Template${scale === 1 ? "" : `@${scale}x`}.png`;
      const buffer = await sharp(Buffer.from(svg), { density: 72 * scale * 4 })
        .resize(size, size, { fit: "contain", background: TRANSPARENT })
        .png()
        .toBuffer();
      await assertNotBlank(buffer, file);
      for (const dir of [generated, trayIcons]) {
        const outFile = path.join(dir, file);
        await writeFile(outFile, buffer);
        log(`wrote ${outFile}`);
      }
    }
  }

  await writeAppIcon(generated, log);
}

const invokedDirectly = process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invokedDirectly) {
  await makeIcons();
}
