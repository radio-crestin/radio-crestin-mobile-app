/**
 * The small Markdown subset the release notes use, rendered for slides:
 * paragraphs, `-` and `1.` lists (with indented continuation lines),
 * **bold**, *italic*, `code`, [links](url) and images.
 */

export type Image = { src: string; alt: string };

const COMMENT = /<!--([\s\S]*?)-->/g;
const HTML_IMAGE = /<img\b[^>]*>/g;
const MD_IMAGE = /!\[([^\]]*)\]\(([^)\s]+)\)/g;

/** The value of a `<!-- key: value -->` comment, or undefined. */
export function directive(text: string, key: string): string | undefined {
  for (const [, body] of text.matchAll(COMMENT)) {
    const match = body.trim().match(new RegExp(`^${key}:\\s*([\\s\\S]*)$`));
    if (match) return match[1].replace(/\s+/g, " ").trim();
  }
  return undefined;
}

/** Every image in the text, Markdown or `<img>`, in order. */
export function images(text: string): Image[] {
  const found: { at: number; image: Image }[] = [];
  for (const m of text.matchAll(MD_IMAGE))
    found.push({ at: m.index!, image: { alt: m[1], src: m[2] } });
  for (const m of text.matchAll(HTML_IMAGE)) {
    const src = attribute(m[0], "src");
    if (src) found.push({ at: m.index!, image: { src, alt: attribute(m[0], "alt") ?? "" } });
  }
  return found.sort((a, b) => a.at - b.at).map((f) => f.image);
}

const attribute = (tag: string, name: string) =>
  tag.match(new RegExp(`\\b${name}="([^"]*)"`))?.[1];

export type Block =
  | { kind: "paragraph"; lines: string[] }
  | { kind: "list"; ordered: boolean; items: string[] };

/** Splits text (without comments or images) into paragraphs and lists. */
export function blocks(text: string): Block[] {
  const clean = text
    .replace(COMMENT, "")
    .replace(/<p>\s*(<img\b[^>]*>\s*)+<\/p>/g, "")
    .replace(HTML_IMAGE, "")
    .replace(MD_IMAGE, "");
  const result: Block[] = [];
  let current: Block | undefined;
  for (const raw of clean.split("\n")) {
    const line = raw.trimEnd();
    const item = line.match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
    if (!line.trim()) {
      current = undefined;
    } else if (item && item[1].length === 0) {
      const ordered = /\d/.test(item[2]);
      if (current?.kind !== "list" || current.ordered !== ordered) {
        current = { kind: "list", ordered, items: [] };
        result.push(current);
      }
      current.items.push(item[3]);
    } else if (current?.kind === "list" && /^\s+/.test(line)) {
      current.items[current.items.length - 1] += " " + line.trim();
    } else if (current?.kind === "paragraph") {
      current.lines.push(line.trim());
    } else {
      current = { kind: "paragraph", lines: [line.trim()] };
      result.push(current);
    }
  }
  return result;
}

export const escapeHtml = (text: string) =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** Inline Markdown to HTML: code, links, bold, italic. */
export function inline(text: string): string {
  const codes: string[] = [];
  let html = escapeHtml(text).replace(/`([^`]+)`/g, (_, code) => {
    codes.push(`<code>${code}</code>`);
    return `\u0000${codes.length - 1}\u0000`;
  });
  html = html
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, href) =>
      `<a href="${linkTarget(href)}">${label}</a>`)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
  return html.replace(/\u0000(\d+)\u0000/g, (_, i) => codes[Number(i)]);
}

/** Links between notes point at GitHub, since a deck or video has no repo beside it. */
let linkBase = "";
export const setLinkBase = (base: string) => (linkBase = base);
const linkTarget = (href: string) =>
  /^(https?:|mailto:|#)/.test(href) || !linkBase ? href : `${linkBase}/${href}`;

/** Plain text of inline Markdown, for captions and fallbacks. */
export const plain = (text: string) =>
  text
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/[*`]/g, "")
    .trim();
