---
title: Maintaining this site
description: How the docs site works and the everyday recipes - edit a page, add a page, update a diagram.
---

This site is built from the markdown in the repo's `docs/` folder by
[Astro Starlight](https://starlight.astro.build/) (scaffolded under `website/`) and
deployed to GitHub Pages by the `Deploy docs site` GitHub Action on every push to
`main` that touches `docs/` or `website/`. **For normal doc edits you never run
anything** — the toolchain lives entirely in CI, with versions pinned by
`website/package-lock.json`.

## Edit an existing page

Edit the `.md` file under `docs/`, commit, push. The Action rebuilds and deploys in
a couple of minutes.

## Add a page

1. Create `docs/<section>/<name>.md` (lowercase-kebab filename) starting with:

   ```markdown
   ---
   title: My page title
   description: One sentence used for SEO and link previews.
   ---
   ```

   A missing `title` **fails the build** — that's the guardrail.

2. Add the page's slug (path without `.md`) to the `sidebar` list in
   `website/astro.config.mjs` — copy an existing line, e.g. `'features/my-page'`.

3. Commit and push both files.

## Links and images

- Link between pages with **relative `.md` links**
  (`[Settings](../features/settings.md)`) — they work on GitHub and are rewritten to
  site URLs at build time.
- Don't link site pages to `docs/README.md`, `docs/diagrams/*`, or `docs/plans/*` —
  those are GitHub-only (excluded from the site). Use a full GitHub URL instead.
- Reference diagram SVGs as `/DONUT/diagrams/<name>.svg`.

## Update a diagram

Edit the `.puml` source in `docs/diagrams/` and push — CI re-renders every diagram
on each build. The SVG name matches the source filename (keep the `@startuml <name>`
line equal to the filename). To preview locally, run:

```powershell
.\tools\Render-Diagrams.ps1   # needs Java; output in website/public/diagrams/
```

## Preview the whole site locally (optional)

One-time: install Node LTS (`winget install -e --id OpenJS.NodeJS.LTS`). Then:

```powershell
cd website
npm ci                # exact pinned dependencies
npm run build         # full build incl. search index
npx astro preview     # serves http://localhost:4321/DONUT/
```

(Search only works in a built site, not in `npm run dev`.)

## Update the toolchain (rare, optional)

```powershell
cd website
npm update
npm run build         # verify it still builds
```

Commit `package.json` + `package-lock.json` together. If a build ever breaks after
an update, `git checkout -- package.json package-lock.json` puts you back on the
last known-good pin.

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| Build fails with a schema error naming a file | That page is missing `title` (or `description`) frontmatter |
| A page 404s on the site | Slug missing from `sidebar` in `astro.config.mjs`, or the link forgot the `/DONUT/` base |
| Diagram image broken | SVG name doesn't match the `.puml` filename / `@startuml` name |
| Search finds nothing locally | You're in `npm run dev` — search indexes only on `npm run build` |
