/**
 * Release media from release-notes/<tag>.md:
 *
 *   bun src/main.ts deck  v1.6.0            presentation.html only
 *   bun src/main.ts video v1.6.0            presentation.html + narrated video.mp4
 *   bun src/main.ts notes v1.6.0 --repo o/r the GitHub release body, on stdout
 *
 * Output goes to dist/release-media/<tag>/ (override with --out <folder>).
 */
import { copyFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { renderDeck } from "./deck.ts";
import { githubNotes } from "./github.ts";
import { setLinkBase } from "./markdown.ts";
import { setupSlides, versionSlides, type Slide } from "./notes.ts";
import type { Scene } from "./video.ts";

const ROOT = resolve(import.meta.dir, "../../..");
const NOTES = join(ROOT, "release-notes");
const ICON = join(ROOT, "assets/icons/ic_logo_filled.png");
const DEFAULT_REPO = "radio-crestin/radio-crestin-mobile-app";

const [command, tag, ...flags] = process.argv.slice(2);
const flag = (name: string) => {
  const at = flags.indexOf(`--${name}`);
  return at >= 0 ? flags[at + 1] : undefined;
};

async function main() {
  if (!["deck", "video", "notes"].includes(command) || !/^v\d+\.\d+\.\d+$/.test(tag ?? ""))
    fail("usage: bun src/main.ts deck|video|notes v1.2.3 [--out folder] [--repo owner/name]");
  const notes = join(NOTES, `${tag}.md`);
  if (!existsSync(notes)) fail(`${notes} is missing: write the release notes first (see release-notes/README.md)`);
  const repo = flag("repo") ?? DEFAULT_REPO;

  if (command === "notes") {
    process.stdout.write(githubNotes(notes, { repo, tag }));
    return;
  }
  const out = resolve(flag("out") ?? join(ROOT, "dist/release-media", tag));
  mkdirSync(out, { recursive: true });
  setLinkBase(`https://github.com/${repo}/blob/${tag}/release-notes`);
  const slides = allSlides(notes, repo);
  const deck = join(out, "presentation.html");
  writeFileSync(deck, renderDeck(slides, { version: tag.slice(1), icon: ICON }));
  console.log(`${slides.length} slides → ${deck}`);
  if (command === "video") await video(slides, deck, out);
}

function allSlides(notes: string, repo: string): Slide[] {
  const end: Slide = {
    kind: "end", kicker: "", title: "Thank you for listening",
    blocks: [{ kind: "paragraph", lines: [
      `Every download: [github.com/${repo}/releases](https://github.com/${repo}/releases)\\`,
      "Stations and news: [radiocrestin.ro](https://www.radiocrestin.ro)",
    ] }],
    images: [],
    say: "Thank you for listening. Every download is on GitHub, and the stations are at radio crestin dot r o.",
  };
  return [...versionSlides(notes), ...setupSlides(join(NOTES, "SETUP.md")), end];
}

async function video(slides: Slide[], deck: string, out: string) {
  // Loaded only here: the voice model's runtime is heavy, and deck/notes don't need it.
  const { narrate } = await import("./narrate.ts");
  const { buildVideo, screenshotSlide } = await import("./video.ts");
  const scenes: Scene[] = [];
  for (const [index, slide] of slides.entries()) {
    const image = join(out, "slides", `${String(index + 1).padStart(2, "0")}.png`);
    mkdirSync(join(out, "slides"), { recursive: true });
    await screenshotSlide(deck, index, image);
    const voice = await narrate(slide.say, join(out, "voice"));
    scenes.push({ title: slide.title, image, voice: voice.path, voiceSeconds: voice.seconds });
    console.log(`${index + 1}/${slides.length} ${slide.title} (${voice.seconds.toFixed(1)} s)`);
  }
  const path = join(out, "video.mp4");
  const seconds = await buildVideo(scenes, join(out, "build"), path);
  const minutes = `${Math.floor(seconds / 60)}:${String(Math.round(seconds % 60)).padStart(2, "0")}`;
  console.log(`video ${minutes} → ${path}`);
  copyFileSync(join(out, "slides", "01.png"), join(out, "poster.png"));
}

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}

await main();
