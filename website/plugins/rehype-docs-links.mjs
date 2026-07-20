import path from 'node:path';
import { visit } from 'unist-util-visit';

const DOCS_ROOT = path.resolve(import.meta.dirname, '../../docs');
const BASE = '/DONUT/';

/**
 * Rewrites relative *.md links (the GitHub-native authoring style used in docs/)
 * to final site URLs; external, absolute, and pure-anchor links pass through.
 */
export default function rehypeDocsLinks() {
  return (tree, file) => {
    visit(tree, 'element', (node) => {
      const href = node.properties?.href;
      if (node.tagName !== 'a' || typeof href !== 'string') return;
      if (/^(?:[a-z]+:)?\/\//i.test(href) || href.startsWith('#') || href.startsWith('/')) return;
      const match = href.match(/^([^#?]*\.mdx?)([#?].*)?$/i);
      if (!match) return;
      const target = path.resolve(path.dirname(file.path), match[1]);
      let rel = path.relative(DOCS_ROOT, target).split(path.sep).join('/');
      if (!rel || rel.startsWith('..')) return;
      rel = rel.replace(/\.mdx?$/i, '').replace(/(^|\/)index$/i, '$1').replace(/\/$/, '');
      node.properties.href = BASE + (rel ? `${rel}/` : '') + (match[2] ?? '');
    });
  };
}
