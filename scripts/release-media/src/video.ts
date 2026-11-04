import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export type Scene = { title: string; image: string; voice: string; voiceSeconds: number };

const LEAD = 0.5;
const TAIL = 0.9;
const MIN_SECONDS = 4;
const FADE = 0.25;

const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/** Renders slide `index` (0-based) of the deck to a 1920x1080 PNG. */
export async function screenshotSlide(deck: string, index: number, out: string): Promise<void> {
  const profile = mkdtempSync(join(tmpdir(), "release-media-chrome-"));
  const url = `${pathToFileURL(deck).href}?render#${index + 1}`;
  try {
    await run(CHROME, [
      "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
      "--force-device-scale-factor=1", "--window-size=1920,1080", "--virtual-time-budget=1500",
      `--user-data-dir=${profile}`, `--screenshot=${out}`, url,
    ]);
  } finally {
    rmSync(profile, { recursive: true, force: true });
  }
  if (!existsSync(out)) throw new Error(`Chrome did not render slide ${index + 1}`);
}

/**
 * The video's poster for the GitHub release, a 1280 px JPEG: the first slide, dimmed, under a play
 * button and the video's length, so it reads as a video to click.
 */
export async function renderPoster(slide: string, length: string, out: string): Promise<void> {
  const work = mkdtempSync(join(tmpdir(), "release-media-poster-"));
  const page = join(work, "poster.html");
  const png = join(work, "poster.png");
  writeFileSync(page, posterHtml(pathToFileURL(slide).href, length));
  try {
    await run(CHROME, [
      "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
      "--force-device-scale-factor=1", "--window-size=1920,1080", "--virtual-time-budget=1500",
      "--allow-file-access-from-files", `--user-data-dir=${join(work, "profile")}`, `--screenshot=${png}`,
      pathToFileURL(page).href,
    ]);
    await run("ffmpeg", ["-v", "error", "-y", "-i", png, "-vf", "scale=1280:-2", "-q:v", "3", out]);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

function posterHtml(slide: string, length: string): string {
  return `<!doctype html><meta charset="utf-8"><style>
body { margin: 0; width: 1920px; height: 1080px; position: relative; font-family: -apple-system, sans-serif;
  background: url("${slide}") center / cover; }
.dim { position: absolute; inset: 0; background: rgba(0, 0, 0, 0.55); }
.play { position: absolute; left: 50%; top: 50%; width: 220px; height: 220px; margin: -110px 0 0 -110px;
  border-radius: 50%; background: #E91E63; box-shadow: 0 16px 56px rgba(0, 0, 0, 0.5); }
.play::after { content: ""; position: absolute; left: 84px; top: 55px; border-style: solid;
  border-width: 55px 0 55px 92px; border-color: transparent transparent transparent #fff; }
.label { position: absolute; left: 50%; top: calc(50% + 150px); transform: translateX(-50%); color: #fff;
  font-size: 44px; font-weight: 600; padding: 14px 34px; border-radius: 999px; background: #141414; box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5); }
</style><div class="dim"></div><div class="play"></div><div class="label">What's new · ${length}</div>`;
}

/** Joins the scenes into one mp4 with a chapter per scene. Unchanged scenes are reused from `work`. */
export async function buildVideo(scenes: Scene[], work: string, out: string): Promise<number> {
  mkdirSync(work, { recursive: true });
  const segments: string[] = [];
  const chapters: { title: string; start: number; end: number }[] = [];
  let clock = 0;
  for (const scene of scenes) {
    const seconds = Math.max(MIN_SECONDS, LEAD + scene.voiceSeconds + TAIL);
    segments.push(await segment(scene, seconds, work));
    chapters.push({ title: scene.title, start: clock, end: clock + seconds });
    clock += seconds;
  }
  const list = join(work, "segments.txt");
  writeFileSync(list, segments.map((path) => `file '${path}'`).join("\n"));
  const metadata = join(work, "chapters.txt");
  writeFileSync(metadata, ffmetadata(chapters));
  await run("ffmpeg", [
    "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list, "-i", metadata,
    "-map", "0", "-map_metadata", "1", "-map_chapters", "1", "-c", "copy", "-movflags", "+faststart", out,
  ]);
  return clock;
}

async function segment(scene: Scene, seconds: number, work: string): Promise<string> {
  const key = createHash("sha256")
    .update(readFileSync(scene.image)).update(readFileSync(scene.voice)).update(String(seconds))
    .digest("hex").slice(0, 16);
  const out = join(work, `segment-${key}.mp4`);
  if (existsSync(out)) return out;
  const delay = Math.round(LEAD * 1000);
  const fadeOut = (seconds - FADE).toFixed(3);
  await run("ffmpeg", [
    "-y", "-v", "error",
    "-loop", "1", "-framerate", "30", "-t", seconds.toFixed(3), "-i", scene.image,
    "-i", scene.voice,
    "-filter_complex",
    `[0:v]format=yuv420p,fade=t=in:st=0:d=${FADE},fade=t=out:st=${fadeOut}:d=${FADE}[v];` +
      `[1:a]aresample=48000,adelay=${delay}:all=1,apad,atrim=0:${seconds.toFixed(3)}[a]`,
    "-map", "[v]", "-map", "[a]",
    "-c:v", "libx264", "-tune", "stillimage", "-preset", "medium", "-crf", "20", "-r", "30",
    "-c:a", "aac", "-b:a", "160k", "-ac", "2",
    "-t", seconds.toFixed(3), out,
  ]);
  return out;
}

function ffmetadata(chapters: { title: string; start: number; end: number }[]): string {
  const escape = (text: string) => text.replace(/([=;#\\\n])/g, "\\$1");
  return [";FFMETADATA1", "title=Radio Crestin: what's new", ...chapters.flatMap((chapter) => [
    "[CHAPTER]", "TIMEBASE=1/1000",
    `START=${Math.round(chapter.start * 1000)}`, `END=${Math.round(chapter.end * 1000)}`,
    `title=${escape(chapter.title)}`,
  ])].join("\n") + "\n";
}

function run(command: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (data) => (stderr += data));
    child.on("error", reject);
    child.on("close", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} exited ${code}: ${stderr.slice(-800)}`)));
  });
}
