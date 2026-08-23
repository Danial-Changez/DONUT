import fs from 'node:fs';
import path from 'node:path';
import { visit } from 'unist-util-visit';
import { base } from '../site-base.mjs';

const DOCS_ROOT = path.resolve(import.meta.dirname, '../../docs');
const PUBLIC_ROOT = path.resolve(import.meta.dirname, '../public');
// site-base exports the Astro form (no trailing slash, or '/' for a root site);
// joining wants a trailing slash.
const BASE = base.endsWith('/') ? base : `${base}/`;

// Astro does not base-prefix absolute paths in Markdown, so authors write these
// base-less and the prefix is applied here, keeping the base in one place.
const ASSET_PREFIXES = ['/diagrams/'];

/** Join BASE (trailing slash) onto a root-absolute path (leading slash). */
function withBase(url) {
  return BASE + url.slice(1);
}

/**
 * Intrinsic size of a rendered SVG under public/, from its width/height or
 * viewBox, so the <img> reserves its box before it loads. Null when the file is
 * not there yet (the CI renders diagrams before the build; a local dev server
 * may not have them).
 */
function svgSize(publicPath) {
  try {
    const head = fs.readFileSync(path.join(PUBLIC_ROOT, publicPath), 'utf8').slice(0, 2048);
    const attr = (name) => head.match(new RegExp(`\\s${name}="([\\d.]+)(?:px)?"`))?.[1];
    let w = attr('width');
    let h = attr('height');
    if (!w || !h) {
      const box = head.match(/viewBox="[\d.-]+\s+[\d.-]+\s+([\d.]+)\s+([\d.]+)"/);
      if (box) [, w, h] = box;
    }
    return w && h ? { width: Math.round(Number(w)), height: Math.round(Number(h)) } : null;
  } catch {
    return null;
  }
}

/**
 * Rewrites relative *.md links (the GitHub-native authoring style used in docs/)
 * to final site URLs, and base-prefixes absolute public-asset paths (diagrams).
 * External, absolute (non-asset), and pure-anchor links pass through. Diagram
 * images also get their intrinsic size and a wrapping button, so the lightbox
 * (components/Head.astro) opens from the keyboard as well as a click.
 */
export default function rehypeDocsLinks() {
  return (tree, file) => {
    visit(tree, 'element', (node, index, parent) => {
      // Base-prefix public assets referenced by absolute path (img src / a href).
      for (const attr of ['href', 'src']) {
        const val = node.properties?.[attr];
        if (typeof val === 'string' && ASSET_PREFIXES.some((p) => val.startsWith(p))) {
          // Only diagrams get the lightbox button; other assets are plain images.
          if (node.tagName === 'img' && attr === 'src' && val.startsWith('/diagrams/')) {
            const size = svgSize(val);
            if (size) Object.assign(node.properties, size);
            if (parent && parent.tagName !== 'button') {
              parent.children[index] = {
                type: 'element',
                tagName: 'button',
                properties: { type: 'button', className: ['dw-diagram'], title: 'Open diagram' },
                children: [node],
              };
            }
          }
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
