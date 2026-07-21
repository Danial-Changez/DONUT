// @ts-check
// Resolve the GitHub Pages deploy URL, shared by astro.config.mjs and the
// docs-link rehype plugin so the base lives in exactly one place.
//
// Precedence:
//  1. actions/configure-pages outputs (piped in as env by the deploy workflow
//     BEFORE the build) — the only source that knows the REAL target, including
//     the random *.pages.github.io root that access-controlled (private)
//     Enterprise Pages use, which is NOT <owner>.github.io/<repo>.
//  2. GITHUB_REPOSITORY ("owner/repo") — a reasonable guess for a plain public
//     project site when configure-pages hasn't run.
//  3. The canonical production values, for local dev where nothing is set.
const pagesOrigin = process.env.PAGES_ORIGIN;
const slug = process.env.GITHUB_REPOSITORY;

/** Site origin, e.g. https://danial-changez.github.io or https://<slug>.pages.github.io */
export const site =
  pagesOrigin ||
  (slug
    ? `https://${slug.split('/')[0].toLowerCase()}.github.io`
    : 'https://danial-changez.github.io');

/** Astro base path (leading slash, no trailing), e.g. /DONUT — or / for a root site. */
export const base = (() => {
  // configure-pages reports base_path as "/my-repo" or "" (a root site).
  if (pagesOrigin) {
    const p = process.env.PAGES_BASE_PATH || '';
    return p && p !== '/' ? p.replace(/\/$/, '') : '/';
  }
  if (!slug) return '/DONUT';
  const [owner, repo] = slug.split('/');
  // A repo named <owner>.github.io is the user/org root site, served from '/'.
  return repo.toLowerCase() === `${owner.toLowerCase()}.github.io` ? '/' : `/${repo}`;
})();

/** Source repository URL, e.g. https://github.com/Danial-Changez/DONUT */
export const repo = `https://github.com/${slug ?? 'Danial-Changez/DONUT'}`;
