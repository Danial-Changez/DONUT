import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

export const collections = {
  docs: defineCollection({
    // README indexes, diagram sources, and archived plans stay GitHub-only.
    loader: glob({
      pattern: ['**/*.{md,mdx}', '!**/README.md', '!diagrams/**', '!plans/**'],
      base: '../docs',
      // The root must stay 'index', as Astro rejects an empty id.
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
