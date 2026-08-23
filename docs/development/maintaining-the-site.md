---
title: Maintaining this site
description: How the docs site works and the everyday recipes - edit a page, add a page, update a diagram.
---

This site is built from the markdown in `docs/` by
[Astro Starlight](https://starlight.astro.build/) (scaffolded under `web/`) and
deployed to GitHub Pages on every push to `main` that touches `docs/` or `web/`.
**For normal doc edits you never run anything.** The toolchain lives in CI.

## House style

- **Keep user and developer docs separate.** `get-started/`, `features/`, and
  `configuration/` tell an operator what to do; they carry no class names, no
  `src/` paths, no internal vocabulary, no diagrams, and no maintainer
  instructions. Everything about *how it works* lives under `development/`.
- **Short over complete.** Short paragraphs, numbered steps for procedures, tables
  for enumerable facts. If a paragraph runs past four sentences, it is probably a
  list. A bullet is a line, not a paragraph.
- **Plain connectors.** No em or en dashes outside UI text: a comma, a colon, or a
  second sentence. The same rule the [coding style](./coding-style.md) sets for
  comments.
- **Say it once.** A fact stated on another page is linked, not repeated.
- **Rules on reference pages, history in
  [Design decisions](./decisions.md).** A dated regression, a measurement, or a
  rejected alternative goes in the appendix; the reference page states the rule and
  links to it.
- Admonitions are short and reserved for warnings, not a place to park
  explanation.

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

   A missing `title` **fails the build**; that's the guardrail.

2. Add the page's slug (path without `.md`) to the `sidebar` list in
   `web/astro.config.mjs`. Copy an existing line, e.g. `'features/my-page'`.

3. Commit and push both files.

## Links and images

- Link between pages with **relative `.md` links**
  (`[Settings](../features/settings.md)`). They work on GitHub and are rewritten to
  site URLs at build time.
- Don't link site pages to `docs/README.md`, `docs/diagrams/*`, or `docs/plans/*`.
  Those are GitHub-only (excluded from the site). Use a full GitHub URL instead.
- Reference diagram SVGs as `/diagrams/<name>.svg` (base-less). The build prefixes
  the deploy base, so the path stays correct if the repo is renamed or moved.
  Don't hardcode the `/DONUT/` base.
- The same plugin wraps each diagram in a button, so the lightbox opens from the
  keyboard, and stamps its width and height from the rendered SVG.
- Astro caches rendered pages in `web/node_modules/.astro`, keyed on the Markdown
  file. After editing the plugin, delete that folder before a local build.
- The splash screenshot lives at `web/public/screenshots/home.png` (a copy sits
  in `assets/Screenshots/`). To refresh it after a UI change, run
  `pwsh -Sta -File tools\Show-View.ps1 -Main -Screenshot home.png` and replace
  both copies; the harness composes the main window with sample data, so no
  fleet is needed. Reference it base-less as `/screenshots/<name>.png`.

## Update a diagram

Edit the `.puml` source in `docs/diagrams/` and push. CI re-renders every diagram
on each build. The SVG name matches the source filename (keep the `@startuml <name>`
line equal to the filename). To preview locally, run:

```powershell
.\tools\Render-Diagrams.ps1   # needs Java; output in web/public/diagrams/
```

## Preview the whole site locally (optional)

One-time: install Node LTS (`winget install -e --id OpenJS.NodeJS.LTS`). Then:

```powershell
cd web
npm ci                # exact pinned dependencies
npm run build         # full build incl. search index
npx astro preview     # serves http://localhost:4321/DONUT/
```

(Search only works in a built site, not in `npm run dev`.)

## Checks (optional)

The site has Prettier, ESLint, and `astro check` configured. From `web/`:

```powershell
npm run verify   # format check + lint + type-check (what CI runs)
npm run format   # auto-fix formatting
```

The `Web checks` GitHub Action runs `npm run verify` on every push / PR that touches
`web/`. It reports a failing check but doesn't block the deploy.

## Update the toolchain (rare, optional)

```powershell
cd web
npm update
npm run build         # verify it still builds
```

Commit `package.json` + `package-lock.json` together; `git checkout --` on both
restores the last known-good pin.

## Troubleshooting

| Symptom | Cause |
|---------|-------|
| Build fails with a schema error naming a file | That page is missing `title` (or `description`) frontmatter |
| A page 404s on the site | Slug missing from `sidebar` in `astro.config.mjs`, or a link used an absolute path instead of a relative `.md` link |
| Diagram image broken | SVG name doesn't match the `.puml` filename / `@startuml` name |
| Search finds nothing locally | You're in `npm run dev`; search indexes only on `npm run build` |
