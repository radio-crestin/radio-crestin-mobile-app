# Release notes

What changed in each version of Radio Crestin, written for listeners: one file per version, the source of
the GitHub release body, the presentation and the narrated video.
Open it when you ship something listeners will notice, or when you prepare a release.

Find a change across versions with grep, e.g. `grep -n -i "carplay" release-notes/v*.md`.

## Files

| File | What it holds |
|------|---------------|
| `vX.Y.Z.md` | One version's changes. The newest file whose status is "not released yet" collects the work in progress. |
| [`SETUP.md`](SETUP.md) | How to install and set up the app on every device type. Every release links to it; the presentation and video end with it. |
| `media/vX.Y.Z/` | Screenshots used by that version's notes (JPEG, 720 px wide). |

## Writing a version file

Copy the shape of [v1.6.0.md](v1.6.0.md):

- `# Radio Crestin X.Y.Z`, then a status line (`**Status:** not released yet` until it ships, then
  `**Released:** <date>`), the version it follows, and the platforms. End a line with ` \` to keep the
  next one on its own line.
- A summary paragraph, for listeners: what they will notice, not how it was built.
- `## Highlights` with one `### Title` per feature (each becomes a slide), then `## More improvements` and
  `## Fixes`, grouped the same way. `## Under the hood` is for developers.
- Under each heading, the line the narrator says over its slide, in a comment GitHub doesn't show:
  `<!-- say: Search now happens right on Home. -->`. About 35 words (15 seconds); spell out what should
  be read differently ("version one point six", "T V", "A P K"). Romanian names may be written as they
  are: the narrator's pronunciations are in `scripts/release-media/src/narrate.ts`.
- `<!-- slides: skip -->` under a heading keeps it (and its subsections) out of the presentation and video.
- Screenshots: `<p><img src="media/vX.Y.Z/name.jpg" alt="…" width="240"></p>`; up to three per slide,
  shown as phones beside the text.

Keep the Romanian labels exactly as the app shows them (**Încărcare în avans**), with the English meaning
nearby.

## Presentation and video

Built from the version file plus `SETUP.md` by `scripts/release-media` (Bun; Chrome renders the slides,
ffmpeg joins them, Kokoro-82M speaks on this machine, the same voice Superfactory's video studio uses):

```bash
make release-deck  TAG=v1.6.0   # slides only → dist/radio-crestin-whats-new.html
make release-media TAG=v1.6.0   # slides + narrated video → dist/radio-crestin-whats-new.{html,mp4}
```

`TAG` defaults to the pubspec version. In the presentation: ← → move, **N** shows the narration,
**F** goes fullscreen, and printing saves every slide as a PDF page. The video has a chapter per slide.
Lines that didn't change are not spoken again, so rebuilding after an edit takes seconds per changed slide.

The GitHub release opens with the video: its poster (the first slide under a play button, attached as
`radio-crestin-whats-new.jpg`) links to the mp4. GitHub plays inline only videos uploaded through its web
editor, so the release links to the attached file instead.

## Releasing

The release steps are in [CLAUDE.md → Releases](../CLAUDE.md#releases).
