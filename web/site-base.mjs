// @ts-check
// GitHub Pages serves a project site at https://<owner>.github.io/<repo>/, both
// derivable from GITHUB_REPOSITORY ("owner/repo"), which Actions sets. Deriving
// them here — shared by astro.config.mjs and the docs-link rehype plugin so the
// base lives in exactly one place — means moving the repo to a new owner/name
// needs no edit. Locally the var is unset, so fall back to the production values.
const slug = process.env.GITHUB_REPOSITORY;

/** Site origin, e.g. https://danial-changez.github.io */
export const site = slug
  ? `https://${slug.split('/')[0].toLowerCase()}.github.io`
  : 'https://danial-changez.github.io';

/** Astro base path (leading slash, no trailing), e.g. /DONUT — or / for a root site. */
export const base = (() => {
  if (!slug) return '/DONUT';
  const [owner, repo] = slug.split('/');
  // A repo named <owner>.github.io is the user/org root site, served from '/'.
  return repo.toLowerCase() === `${owner.toLowerCase()}.github.io` ? '/' : `/${repo}`;
})();

/** Source repository URL, e.g. https://github.com/Danial-Changez/DONUT */
export const repo = `https://github.com/${slug ?? 'Danial-Changez/DONUT'}`;
