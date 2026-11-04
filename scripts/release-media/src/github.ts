import { readFileSync } from "node:fs";

/**
 * A version's notes as a GitHub release body: the narration comments and the `#` title go (the
 * release has its own title), and links and images to files beside the notes point at the tag.
 */
export function githubNotes(path: string, { repo, tag }: { repo: string; tag: string }): string {
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
