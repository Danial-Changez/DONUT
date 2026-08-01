// @ts-check
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'astro/config';
import { unified } from '@astrojs/markdown-remark';
import starlight from '@astrojs/starlight';
import rehypeDocsLinks from './plugins/rehype-docs-links.mjs';
import { site, base, repo } from './site-base.mjs';

export default defineConfig({
  site,
  base,
  vite: {
    resolve: {
      alias: [
        // Content lives outside this project root (../docs), so bare imports in
        // .mdx files can't walk up to our node_modules - pin the one they use.
        // Exact match only: Starlight itself imports components/*.astro subpaths.
        {
          find: /^@astrojs\/starlight\/components$/,
          replacement: fileURLToPath(
            new URL('./node_modules/@astrojs/starlight/components.ts', import.meta.url),
          ),
        },
      ],
    },
  },
  markdown: {
    // The flat markdown.remarkPlugins/rehypePlugins options are deprecated; the
    // supported path is a unified() processor. Starlight detects this processor
    // (isUnifiedProcessor) and pushes its own plugins (asides, heading anchors,
    // Shiki) into it, so ours composes with Starlight's rather than replacing it.
    // gfm/smartypants are omitted, so they keep the framework defaults (on).
    processor: unified({
      rehypePlugins: [rehypeDocsLinks],
    }),
  },
  integrations: [
    starlight({
      title: 'DONUT',
      description:
        'A fleet management app for Dell workstations - AD search, remote driver updates through Dell Command Update, hardware inventory, and user-to-device lookup.',
      // The wordmark already spells DONUT, so it replaces the text title.
      logo: { src: './src/assets/logo.png', alt: 'DONUT', replacesTitle: true },
      favicon: '/favicon.ico',
      social: [{ icon: 'github', label: 'GitHub', href: repo }],
      customCss: [
        '@fontsource/geist-sans/400.css',
        '@fontsource/geist-sans/500.css',
        '@fontsource/geist-sans/600.css',
        '@fontsource/geist-sans/700.css',
        '@fontsource/geist-mono/400.css',
        '@fontsource/geist-mono/500.css',
        './src/styles/custom.css',
      ],
      components: {
        // DONUT is dark-only; this empty component removes the theme toggle.
        ThemeSelect: './src/components/ThemeSelect.astro',
        // Stock search + a quick-links empty state (see components/Search.astro).
        Search: './src/components/Search.astro',
        // Stock head + the diagram lightbox loader (see components/Head.astro).
        Head: './src/components/Head.astro',
      },
      expressiveCode: {
        // Single dark syntax theme so code blocks never flip light.
        themes: ['github-dark'],
      },
      markdown: {
        // Run Starlight's Markdown pipeline (asides, anchors) on the external
        // docs directory, since content loads from outside src/content/docs.
        processedDirs: ['../docs'],
      },
      // Git-based lastUpdated and editLink are unreliable for content outside
      // src/content/docs (known custom-location gaps), so both stay off.
      lastUpdated: false,
      sidebar: [
        {
          label: 'Get Started',
          items: [
            'get-started/what-is-donut',
            'get-started/installation',
            'get-started/first-launch',
          ],
        },
        {
          label: 'Features',
          items: [
            'features/scanning',
            'features/applying-updates',
            'features/machine-list',
            'features/machine-details',
            'features/ad-finder',
            'features/user-lens',
            'features/tray-hotkey-autostart',
            'features/self-update',
            'features/settings',
          ],
        },
        {
          label: 'Configuration',
          items: ['configuration/config-reference', 'configuration/dcu-commands'],
        },
        {
          label: 'Development',
          items: [
            {
              label: 'Architecture',
              items: [
                'development/architecture/overview',
                'development/architecture/runspaces-and-workers',
                'development/architecture/remote-execution',
                'development/architecture/user-lens',
                'development/architecture/ad-queries',
                'development/architecture/ui-and-threading',
                'development/architecture/configuration-and-persistence',
                'development/architecture/elevation',
                'development/architecture/powershell-constraints',
                'development/architecture/key-classes',
                'development/architecture/runtime-flows',
              ],
            },
            'development/coding-style',
            'development/testing',
            'development/ui-reference',
            'development/maintaining-the-site',
          ],
        },
      ],
    }),
  ],
});
