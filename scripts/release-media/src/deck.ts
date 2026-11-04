import { readFileSync } from "node:fs";
import { extname } from "node:path";
import { escapeHtml, inline, type Block, type Image } from "./markdown.ts";
import type { Slide } from "./notes.ts";

/** A self-contained HTML slide deck: images inlined, no network needed. */
export function renderDeck(slides: Slide[], { version, icon }: { version: string; icon: string }): string {
  const sections = slides.map((slide, index) => renderSlide(slide, index, version, icon)).join("\n");
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Radio Crestin ${escapeHtml(version)}</title>
<style>${STYLE}</style>
</head>
<body>
<main class="stage" id="stage">
${sections}
<footer class="chrome">
  <span>Radio Crestin ${escapeHtml(version)}</span>
  <span id="counter"></span>
  <div class="progress"><div id="progress"></div></div>
</footer>
<aside class="notes" id="notes"></aside>
</main>
<p class="hint">← → to move · N narration · F fullscreen</p>
<script>${SCRIPT}</script>
</body>
</html>
`;
}

function renderSlide(slide: Slide, index: number, version: string, icon: string): string {
  const shots = slide.images.length;
  const classes = ["slide", slide.kind, shots ? `shots-${Math.min(shots, 3)}` : "no-shots"];
  const say = escapeHtml(slide.say);
  const kicker = slide.kicker ? `<p class="kicker">${escapeHtml(slide.kicker)}</p>` : "";
  const body = (() => {
    switch (slide.kind) {
      case "title": return titleBody(slide, version, icon);
      case "end": return endBody(slide, icon);
      case "section": return `${kicker}<h1>${escapeHtml(slide.title)}</h1>${renderBlocks(slide.blocks)}`;
      default: return `${kicker}<h2>${escapeHtml(slide.title)}</h2>${renderBlocks(slide.blocks)}`;
    }
  })();
  return `<section class="${classes.join(" ")}" data-index="${index}" data-say="${say}">
  <div class="text">${body}</div>
  ${shots ? renderShots(slide.images) : ""}
</section>`;
}

function titleBody(slide: Slide, version: string, icon: string): string {
  const [meta, ...rest] = slide.blocks;
  const chips = meta?.kind === "paragraph"
    ? meta.lines.flatMap((line) => line.replace(/\\$/, "").split(" · "))
        .map((chip) => `<li>${inline(chip)}</li>`).join("")
    : "";
  return `<div class="brand"><img src="${dataUri(icon)}" alt=""><span>Radio Crestin</span></div>
  <h1 class="version">${escapeHtml(version)}</h1>
  <ul class="chips">${chips}</ul>
  ${renderBlocks(rest)}`;
}

function endBody(slide: Slide, icon: string): string {
  return `<img class="end-icon" src="${dataUri(icon)}" alt="">
  <h1>${escapeHtml(slide.title)}</h1>${renderBlocks(slide.blocks)}`;
}

function renderBlocks(blocks: Block[]): string {
  return blocks.map((block) => {
    if (block.kind === "paragraph") {
      const requirement = /^Needs\b/.test(block.lines[0]) ? ` class="requirement"` : "";
      return `<p${requirement}>${joinLines(block.lines)}</p>`;
    }
    const tag = block.ordered ? "ol" : "ul";
    return `<${tag}>${block.items.map((item) => `<li>${inline(item)}</li>`).join("")}</${tag}>`;
  }).join("\n");
}

function renderShots(images: Image[]): string {
  const figures = images.slice(0, 3)
    .map((image) => `<figure><img src="${dataUri(image.src)}" alt="${escapeHtml(image.alt)}"></figure>`)
    .join("");
  return `<div class="shots">${figures}</div>`;
}

/** Source line breaks are spaces, as on GitHub; a line ending in `\\` keeps its break. */
const joinLines = (lines: string[]) =>
  lines.map((line) => inline(line.replace(/\\$/, ""))
    + (line.endsWith("\\") ? "<br>" : " ")).join("").trim();

const MIME: Record<string, string> = { ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png" };
const dataUri = (path: string) =>
  `data:${MIME[extname(path).toLowerCase()] ?? "image/png"};base64,${readFileSync(path).toString("base64")}`;

const STYLE = String.raw`
:root {
  --pink: #E91E63; --pink-light: #F8BBD0; --wine: #8F0133; --wine-deep: #3a0617;
  --ink: #0f0508; --text: #ffffff; --muted: rgba(255,255,255,.72); --faint: rgba(255,255,255,.14);
  --font: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, system-ui, sans-serif;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { height: 100%; background: #000; overflow: hidden; }
body { font-family: var(--font); color: var(--text); -webkit-font-smoothing: antialiased; }
a { color: var(--pink-light); text-decoration: none; border-bottom: 2px solid rgba(248,187,208,.35); }
code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: .88em;
  background: var(--faint); padding: .05em .3em; border-radius: 6px; }
strong { font-weight: 700; color: #fff; }

.stage { position: absolute; left: 50%; top: 50%; width: 1920px; height: 1080px;
  transform-origin: 0 0; overflow: hidden;
  background:
    radial-gradient(900px 700px at 8% 0%, rgba(233,30,99,.28), transparent 70%),
    radial-gradient(1100px 900px at 100% 100%, rgba(143,1,51,.45), transparent 70%),
    linear-gradient(160deg, var(--wine-deep), var(--ink) 75%); }

.slide { position: absolute; inset: 0; padding: 120px 150px 150px; display: grid;
  grid-template-columns: minmax(0, 1fr) auto; gap: 110px; align-items: center;
  opacity: 0; visibility: hidden; transform: translateX(40px);
  transition: opacity .35s ease, transform .35s cubic-bezier(.2,.7,.2,1), visibility 0s .35s; }
.slide.active { opacity: 1; visibility: visible; transform: none;
  transition: opacity .35s ease, transform .35s cubic-bezier(.2,.7,.2,1); }
.slide.no-shots { grid-template-columns: minmax(0, 1fr); }

.kicker { font-size: 26px; font-weight: 700; letter-spacing: .14em; text-transform: uppercase;
  color: var(--pink); margin-bottom: 22px; }
h1 { font-size: 120px; line-height: 1.02; font-weight: 800; letter-spacing: -.02em; }
h2 { font-size: 76px; line-height: 1.06; font-weight: 800; letter-spacing: -.015em; margin-bottom: 44px; }
.text p { font-size: 34px; line-height: 1.45; color: var(--muted); margin-bottom: 26px; max-width: 1500px; }
.text ul, .text ol { list-style: none; display: grid; gap: 26px; max-width: 1500px; }
.text li { font-size: 34px; line-height: 1.42; color: var(--muted); position: relative; padding-left: 46px; }
.text ul li::before { content: ""; position: absolute; left: 4px; top: .55em; width: 14px; height: 14px;
  border-radius: 50%; background: var(--pink); box-shadow: 0 0 18px rgba(233,30,99,.8); }
.text ol { counter-reset: step; gap: 30px; }
.text ol li { counter-increment: step; padding-left: 78px; }
.text ol li::before { content: counter(step); position: absolute; left: 0; top: -.05em; width: 52px; height: 52px;
  border-radius: 50%; background: var(--pink); color: #fff; font-weight: 800; font-size: 28px;
  display: grid; place-items: center; box-shadow: 0 8px 24px rgba(233,30,99,.45); }
.shots-1 .text li, .shots-2 .text li, .shots-3 .text li { font-size: 31px; }
.setup .text li { font-size: 31px; }

.requirement { display: inline-block; font-size: 26px !important; font-weight: 600; color: var(--pink-light) !important;
  background: rgba(233,30,99,.16); border: 1px solid rgba(233,30,99,.45); border-radius: 999px;
  padding: 8px 24px; margin: -18px 0 38px !important; }

.shots { position: relative; display: flex; align-items: center; justify-content: center; }
.shots figure { border-radius: 52px; overflow: hidden; background: #000; border: 10px solid #1c1c1f;
  box-shadow: 0 40px 90px rgba(0,0,0,.6), 0 0 120px rgba(233,30,99,.22); }
.shots img { display: block; height: 100%; width: auto; }
.shots-1 .shots figure { height: 820px; }
.shots-2 .shots figure { height: 740px; }
.shots-2 .shots figure:first-child { transform: rotate(-4deg) translateX(40px); z-index: 1; }
.shots-2 .shots figure:last-child { transform: rotate(4deg) translate(-40px, 40px); z-index: 2; }
.shots-3 .shots figure { height: 640px; }
.shots-3 .shots figure:nth-child(1) { transform: rotate(-7deg) translate(70px, 30px); z-index: 1; }
.shots-3 .shots figure:nth-child(2) { transform: translateY(-20px); z-index: 3; }
.shots-3 .shots figure:nth-child(3) { transform: rotate(7deg) translate(-70px, 30px); z-index: 2; }

.title .brand { display: flex; align-items: center; gap: 28px; font-size: 52px; font-weight: 700; margin-bottom: 18px; }
.title .brand img { width: 104px; height: 104px; border-radius: 26px; box-shadow: 0 16px 40px rgba(233,30,99,.45); }
.title .version { font-size: 180px; letter-spacing: -.04em; line-height: .95; margin-bottom: 36px;
  background: linear-gradient(100deg, #fff 10%, var(--pink-light) 45%, var(--pink) 90%);
  -webkit-background-clip: text; background-clip: text; color: transparent; }
.title .chips { display: flex; flex-wrap: wrap; gap: 14px; margin-bottom: 40px; }
.title .chips li { padding: 8px 20px; font-size: 22px; border-radius: 999px; background: var(--faint);
  color: var(--muted); }
.title .chips li::before { display: none; }
.title .text p { font-size: 29px; line-height: 1.5; }

.section, .end { text-align: center; justify-items: center; }
.section .text, .end .text { display: grid; justify-items: center; }
.section h1 { font-size: 136px; }
.section p { margin-top: 36px; }
.end .end-icon { width: 180px; height: 180px; border-radius: 44px; margin-bottom: 56px;
  box-shadow: 0 24px 70px rgba(233,30,99,.5); }
.end p { margin-top: 30px; }

.chrome { position: absolute; left: 150px; right: 150px; bottom: 54px; display: flex;
  justify-content: space-between; font-size: 22px; color: rgba(255,255,255,.45); letter-spacing: .04em; }
.progress { position: absolute; left: 0; right: 0; bottom: -22px; height: 5px; border-radius: 3px; background: var(--faint); }
.progress div { height: 100%; border-radius: 3px; background: var(--pink); transition: width .35s ease; }
.notes { position: absolute; left: 150px; right: 150px; bottom: 120px; padding: 26px 34px; border-radius: 22px;
  background: rgba(0,0,0,.78); font-size: 30px; line-height: 1.45; color: #fff; display: none; }
.show-notes .notes { display: block; }
.hint { position: fixed; right: 16px; bottom: 12px; font: 13px var(--font); color: rgba(255,255,255,.4); }

.render .slide { transition: none !important; }
.render .hint { display: none; }

@media print {
  @page { size: 1920px 1080px; margin: 0; }
  html, body { height: auto; overflow: visible; }
  .stage { position: static; transform: none !important; height: auto; background: none; }
  .slide { position: relative; height: 1080px; opacity: 1; visibility: visible; transform: none;
    break-after: page; background: linear-gradient(160deg, var(--wine-deep), var(--ink) 75%); }
  .chrome, .notes, .hint { display: none; }
}
`;

const SCRIPT = String.raw`
const stage = document.getElementById("stage");
const slides = [...document.querySelectorAll(".slide")];
const counter = document.getElementById("counter");
const progress = document.getElementById("progress");
const notes = document.getElementById("notes");
if (new URLSearchParams(location.search).has("render")) document.body.classList.add("render");
let current = 0;

function fit() {
  const scale = Math.min(innerWidth / 1920, innerHeight / 1080);
  stage.style.transform = "scale(" + scale + ") translate(-50%, -50%)";
}
function show(index) {
  current = Math.max(0, Math.min(slides.length - 1, index));
  slides.forEach((slide, i) => slide.classList.toggle("active", i === current));
  counter.textContent = (current + 1) + " / " + slides.length;
  progress.style.width = ((current + 1) / slides.length * 100) + "%";
  notes.textContent = slides[current].dataset.say;
  history.replaceState(null, "", "#" + (current + 1));
}
const fromHash = () => (parseInt(location.hash.slice(1), 10) || 1) - 1;

addEventListener("resize", fit);
addEventListener("hashchange", () => show(fromHash()));
addEventListener("keydown", (event) => {
  const moves = { ArrowRight: 1, ArrowDown: 1, PageDown: 1, " ": 1, ArrowLeft: -1, ArrowUp: -1, PageUp: -1 };
  if (event.key in moves) { event.preventDefault(); show(current + moves[event.key]); }
  else if (event.key === "Home") show(0);
  else if (event.key === "End") show(slides.length - 1);
  else if (event.key.toLowerCase() === "n") document.body.classList.toggle("show-notes");
  else if (event.key.toLowerCase() === "f")
    document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen();
});
addEventListener("click", (event) => {
  if (event.target.closest("a")) return;
  show(current + (event.clientX < innerWidth / 3 ? -1 : 1));
});
let touchX = null;
addEventListener("touchstart", (event) => { touchX = event.touches[0].clientX; }, { passive: true });
addEventListener("touchend", (event) => {
  const dx = event.changedTouches[0].clientX - touchX;
  if (Math.abs(dx) > 50) show(current + (dx < 0 ? 1 : -1));
});
fit();
show(fromHash());
`;
