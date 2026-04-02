// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
  integrations: [
    starlight({
      title: 'NFramework Docs',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/n-framework/' }],
      sidebar: [
        {
          label: 'Core Packages',
          items: [
            {
              label: 'Rust',
              items: [
                {
                  label: 'nframework-core-cli',
                  items: [
                    { label: 'Overview', slug: 'core-packages/rust/nframework-core-cli/overview' },
                    { label: 'References', slug: 'core-packages/rust/nframework-core-cli/references' },
                  ],
                },
              ],
            },
          ],
        },
      ],
    }),
  ],
});
