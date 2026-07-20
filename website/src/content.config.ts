import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

export const collections = {
  docs: defineCollection({
    // Site content lives in repo-root docs/ (GitHub-browsable); README indexes,
    // diagram sources, and archived plans are GitHub-only.
    loader: glob({
      pattern: ['**/*.{md,mdx}', '!**/README.md', '!diagrams/**', '!plans/**'],
      base: '../docs',
      // Mirror docsLoader ids: strip the extension and map index files to their
      // directory. The root index.md must stay 'index' (Astro rejects empty ids);
      // Starlight routes the 'index' id to the site root.
      generateId: ({ entry }) => {
        const id = entry
          .replace(/\.(md|mdx)$/i, '')
          .replace(/(^|\/)index$/i, '$1')
          .replace(/\/$/, '');
        return id === '' ? 'index' : id;
      },
    }),
    schema: docsSchema(),
  }),
};
