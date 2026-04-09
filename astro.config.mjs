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
          label: 'Getting Started',
          link: '/getting-started/',
        },
        {
          label: 'Architecture',
          items: [{ label: 'Overview', link: '/architecture/overview/' }],
        },
        {
          label: 'CLI',
          items: [
            { label: 'Commands', link: '/cli/commands/' },
            { label: 'Templates', link: '/cli/templates/' },
          ],
        },
        {
          label: 'Core Packages',
          items: [
            {
              label: 'Rust',
              items: [
                {
                  label: 'nframework-core-cli',
                  items: [
                    { label: 'Overview', link: '/core-packages/rust/nframework-core-cli/overview/' },
                    { label: 'API References', link: '/core-packages/rust/nframework-core-cli/api-references/' },
                  ],
                },
                {
                  label: 'nframework-core-template',
                  items: [
                    { label: 'Overview', link: '/core-packages/rust/nframework-core-template/overview/' },
                    { label: 'API References', link: '/core-packages/rust/nframework-core-template/api-references/' },
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
