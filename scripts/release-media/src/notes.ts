import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { blocks, directive, images, plain, type Block, type Image } from "./markdown.ts";

export type SlideKind = "title" | "section" | "content" | "setup" | "end";

export type Slide = {
  kind: SlideKind;
  kicker: string;
  title: string;
  blocks: Block[];
  /** Absolute paths. */
  images: Image[];
  /** What the narrator says over the slide. */
  say: string;
};

type Heading = { level: number; title: string; body: string; children: Heading[] };

/** The slides of one version's notes: a title slide, then one per highlight or section. */
export function versionSlides(path: string): Slide[] {
  const [root] = headings(path);
  const slides: Slide[] = [slide("title", "", root, path)];
  for (const section of root.children) {
    if (skipped(section)) continue;
    const parts = section.children.filter((part) => !skipped(part));
    if (section.children.length === 0) {
      slides.push(slide("content", "", section, path));
      continue;
    }
    if (directive(section.body, "say")) slides.push(slide("section", "", section, path));
    for (const part of parts) slides.push(slide("content", section.title, part, path));
  }
  return slides;
}

/** The setup slides: an opening slide, then one per device type. */
export function setupSlides(path: string): Slide[] {
  const [root] = headings(path);
  const kicker = "Install and set up";
  const devices = root.children.filter((device) => !skipped(device));
  return [
    {
      ...slide("section", "", root, path),
      title: kicker,
      blocks: [{ kind: "paragraph", lines: [devices.map((device) => plain(device.title)).join(" · ")] }],
    },
    ...devices.map((device) => slide("setup", kicker, device, path)),
  ];
}

function slide(kind: SlideKind, kicker: string, heading: Heading, path: string): Slide {
  const folder = dirname(path);
  return {
    kind,
    kicker,
    title: plain(heading.title),
    blocks: blocks(heading.body),
    images: images(heading.body).map((image) => ({ ...image, src: resolve(folder, image.src) })),
    say: directive(heading.body, "say") ?? `${plain(heading.title)}.`,
  };
}

const skipped = (heading: Heading) => directive(heading.body, "slides") === "skip";

/** The file's headings (#, ##, ###) as a tree, each with the text under it. */
function headings(path: string): Heading[] {
  const roots: Heading[] = [];
  const open: Heading[] = [];
  let current: Heading | undefined;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const match = line.match(/^(#{1,3})\s+(.*)$/);
    if (!match) {
      if (current) current.body += line + "\n";
      continue;
    }
    current = { level: match[1].length, title: match[2].trim(), body: "", children: [] };
    while (open.length && open[open.length - 1].level >= current.level) open.pop();
    (open.length ? open[open.length - 1].children : roots).push(current);
    open.push(current);
  }
  if (roots.length !== 1) throw new Error(`${path}: expected exactly one # title`);
  return roots;
}
