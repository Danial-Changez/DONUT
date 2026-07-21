import path from 'node:path';
import { visit } from 'unist-util-visit';
import { base } from '../site-base.mjs';

const DOCS_ROOT = path.resolve(import.meta.dirname, '../../docs');
// site-base exports the Astro form (no trailing slash, or '/' for a root site);
// joining wants a trailing slash.
const BASE = base.endsWith('/') ? base : `${base}/`;

// Root-absolute references to build-time public assets — the rendered diagram
// SVGs live in web/public/diagrams/, served under the deploy base. Astro doesn't
// base-prefix absolute paths in Markdown, so authors write them base-less
// (/diagrams/x.svg) and we prefix here, keeping the base in one place
// (site-base.mjs) instead of baked into content that would break on a repo move.
const ASSET_PREFIXES = ['/diagrams/'];

/** Join BASE (trailing slash) onto a root-absolute path (leading slash). */
function withBase(url) {
  return BASE + url.slice(1);
}

/**
 * Rewrites relative *.md links (the GitHub-native authoring style used in docs/)
 * to final site URLs, and base-prefixes absolute public-asset paths (diagrams).
 * External, absolute (non-asset), and pure-anchor links pass through.
 */
export default function rehypeDocsLinks() {
  return (tree, file) => {
    visit(tree, 'element', (node) => {
      // Base-prefix public assets referenced by absolute path (img src / a href).
      for (const attr of ['href', 'src']) {
        const val = node.properties?.[attr];
        if (typeof val === 'string' && ASSET_PREFIXES.some((p) => val.startsWith(p))) {
          node.properties[attr] = withBase(val);
        }
      }

      const href = node.properties?.href;
      if (node.tagName !== 'a' || typeof href !== 'string') return;
      if (/^(?:[a-z]+:)?\/\//i.test(href) || href.startsWith('#') || href.startsWith('/')) return;
      const match = href.match(/^([^#?]*\.mdx?)([#?].*)?$/i);
      if (!match) return;
      const target = path.resolve(path.dirname(file.path), match[1]);
      let rel = path.relative(DOCS_ROOT, target).split(path.sep).join('/');
      if (!rel || rel.startsWith('..')) return;
      rel = rel
        .replace(/\.mdx?$/i, '')
        .replace(/(^|\/)index$/i, '$1')
        .replace(/\/$/, '');
      node.properties.href = BASE + (rel ? `${rel}/` : '') + (match[2] ?? '');
    });
  };
}
