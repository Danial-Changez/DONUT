// Flat config (ESLint 9). Lints our hand-authored .astro / .ts / .mjs sources.
// Formatting is Prettier's job (see .prettierrc.json); nothing here restyles code.
import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';
import astro from 'eslint-plugin-astro';

export default [
  {
    // Build output, framework-generated files, and the vendored Search.astro
    // (a pinned upstream copy we don't own the style of).
    ignores: ['dist/', '.astro/', 'node_modules/', 'src/components/Search.astro'],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...astro.configs['flat/recommended'],
  {
    // Config and build files run in Node (astro.config.mjs, plugins/*, this file).
    files: ['**/*.{js,mjs,cjs,ts,mts}'],
    languageOptions: { globals: { ...globals.node } },
  },
];
