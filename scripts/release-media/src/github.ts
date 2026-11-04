import { readFileSync } from "node:fs";

/** The release's narrated video and its poster, as `make publish` attaches them. */
const VIDEO = "radio-crestin-whats-new.mp4";
const POSTER = "radio-crestin-whats-new.jpg";

/**
 * A version's notes as a GitHub release body: the narrated video first, as its poster linking to
 * it (GitHub plays inline only videos uploaded through its web editor); then the notes, without
 * the narration comments and the `#` title (the release has its own title), with links and
 * images to files beside the notes pointing at the tag.
 */
export function githubNotes(path: string, { repo, tag }: { repo: string; tag: string }): string {
  return videoHeader(repo, tag) + notesBody(path, repo, tag);
}

function videoHeader(repo: string, tag: string): string {
  const download = `https://github.com/${repo}/releases/download/${tag}`;
  const version = tag.slice(1);
  return `<a href="${download}/${VIDEO}"><img src="${download}/${POSTER}" ` +
    `alt="What's new in Radio Crestin ${version}: narrated video" width="720"></a>\n\n` +
    `▶ [Watch what's new in ${version}](${download}/${VIDEO}) (narrated video)\n\n`;
}

function notesBody(path: string, repo: string, tag: string): string {
  const blob = `https://github.com/${repo}/blob/${tag}/release-notes`;
  const raw = `https://raw.githubusercontent.com/${repo}/${tag}/release-notes`;
  const local = (href: string) => !/^(https?:|mailto:|#)/.test(href);
  return readFileSync(path, "utf8")
    .replace(/[ \t]*<!--[\s\S]*?-->[ \t]*\n?/g, "")
    .replace(/^# .*\n+/, "")
    .replace(/(<img\b[^>]*\bsrc=")([^"]+)"/g, (all, start, src) => (local(src) ? `${start}${raw}/${src}"` : all))
    .replace(/(!?)\[([^\]]*)\]\(([^)\s]+)\)/g, (all, bang, label, href) =>
      local(href) ? `${bang}[${label}](${bang ? raw : blob}/${href})` : all)
    .replace(/\n{3,}/g, "\n\n")
    .trim() + "\n";
}
