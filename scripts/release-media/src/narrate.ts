import { createHash } from "node:crypto";
import { closeSync, existsSync, mkdirSync, openSync, readSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { env } from "@huggingface/transformers";
import { KokoroTTS, TextSplitterStream } from "kokoro-js";

/**
 * Kokoro-82M speaking on this machine, as Superfactory's sf-video-studio does: the same kokoro-js
 * version, model and default voice. The model (~90 MB) is downloaded once into the cache Superfactory
 * shares between projects, so a machine that already has it never downloads it again.
 */
const MODEL = "onnx-community/Kokoro-82M-v1.0-ONNX";
export const DEFAULT_VOICE = "af_heart";

const modelCache = () =>
  process.env.KOKORO_CACHE ??
  join(process.env.XDG_CACHE_HOME ?? join(homedir(), ".cache"), "superfactory", "kokoro", "models");

let model: Promise<KokoroTTS> | undefined;
function loadModel(): Promise<KokoroTTS> {
  env.cacheDir = modelCache();
  model ??= KokoroTTS.from_pretrained(MODEL, { dtype: "q8", device: "cpu" });
  return model;
}

/** Romanian words Kokoro would read the English way, respelled so they sound right. */
const PRONUNCIATIONS: [RegExp, string][] = [
  [/\bCre[sș]tin\b/gi, "Kreshteen"],
];

const spoken = (text: string) =>
  PRONUNCIATIONS.reduce((result, [word, sound]) => result.replace(word, sound), text);

export type Narration = { path: string; seconds: number };

/** Speaks `text` into a WAV file in `folder`, reusing the file when the same text was spoken before. */
export async function narrate(written: string, folder: string, voice = DEFAULT_VOICE): Promise<Narration> {
  const text = spoken(written);
  mkdirSync(folder, { recursive: true });
  const key = createHash("sha256").update(`${MODEL}\n${voice}\n${text}`).digest("hex").slice(0, 16);
  const path = join(folder, `${key}.wav`);
  if (!existsSync(path)) writeFileSync(path, await speak(text, voice));
  return { path, seconds: wavSeconds(path) };
}

async function speak(text: string, voice: string): Promise<Buffer> {
  const tts = await loadModel();
  // One sentence at a time: a single call reads at most ~500 tokens.
  const sentences = new TextSplitterStream();
  sentences.push(text);
  sentences.close();
  const chunks: Float32Array[] = [];
  let rate = 24_000;
  for await (const { audio } of tts.stream(sentences, { voice: voice as never })) {
    chunks.push(audio.audio);
    rate = audio.sampling_rate;
  }
  if (!chunks.length) throw new Error(`Kokoro returned no audio for: ${text}`);
  return wav(chunks, rate);
}

/** 16-bit mono PCM WAV. */
function wav(chunks: Float32Array[], rate: number): Buffer {
  const samples = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const buffer = Buffer.alloc(44 + samples * 2);
  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(36 + samples * 2, 4);
  buffer.write("WAVEfmt ", 8);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(rate, 24);
  buffer.writeUInt32LE(rate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36);
  buffer.writeUInt32LE(samples * 2, 40);
  let offset = 44;
  for (const chunk of chunks)
    for (const sample of chunk) {
      buffer.writeInt16LE(Math.round(Math.max(-1, Math.min(1, sample)) * 32767), offset);
      offset += 2;
    }
  return buffer;
}

function wavSeconds(path: string): number {
  const header = Buffer.alloc(44);
  const file = openSync(path, "r");
  readSync(file, header, 0, 44, 0);
  closeSync(file);
  return header.readUInt32LE(40) / header.readUInt32LE(28);
}
