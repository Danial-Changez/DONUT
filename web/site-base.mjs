// @ts-check
// The one place the GitHub Pages deploy URL is resolved, in precedence order:
// - PAGES_ORIGIN, set by configure-pages before the build. The only source that
//   knows a private Enterprise Pages root, which is not owner.github.io/repo.
// - GITHUB_REPOSITORY, a fair guess for a plain public project site.
// - The production values, for local dev where nothing is set.
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
