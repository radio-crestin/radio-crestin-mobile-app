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
