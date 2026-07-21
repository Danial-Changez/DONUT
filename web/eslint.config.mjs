// Flat config (ESLint 9). Lints our hand-authored .astro / .ts / .mjs sources.
// Formatting is Prettier's job (see .prettierrc.json); nothing here restyles code.
import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';
import astro from 'eslint-plugin-astro';

export default [
  {
    // Build output and framework-generated files.
    ignores: ['dist/', '.astro/', 'node_modules/'],
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
