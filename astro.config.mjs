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
              label: '.NET',
              items: [
                {
                  label: 'Persistence',
                  items: [
                    { label: 'Overview', link: '/core-packages/dotnet/persistence/' },
                    { label: 'Entities', link: '/core-packages/dotnet/persistence/entities/' },
                    { label: 'Repositories', link: '/core-packages/dotnet/persistence/repositories/' },
                    { label: 'Query System', link: '/core-packages/dotnet/persistence/query-system/' },
                    { label: 'Interceptors', link: '/core-packages/dotnet/persistence/interceptors/' },
                    { label: 'Data Lifecycle', link: '/core-packages/dotnet/persistence/data-lifecycle/' },
                    { label: 'Configuration & DI', link: '/core-packages/dotnet/persistence/configuration-di/' },
                    { label: 'Integration Guide', link: '/core-packages/dotnet/persistence/integration-guide/' },
                    { label: 'API Reference', link: '/core-packages/dotnet/persistence/api-reference/' },
                    { label: 'Advanced Topics', link: '/core-packages/dotnet/persistence/advanced-topics/' },
                  ],
                },
              ],
            },
            {
              label: 'Rust',
              items: [
                {
                  label: 'CLI Abstractions',
                  items: [
                    { label: 'Overview', link: '/core-packages/rust/nframework-core-cli/overview/' },
                    { label: 'API Reference', link: '/core-packages/rust/nframework-core-cli/api-references/' },
                  ],
                },
                {
                  label: 'Template Engine',
                  items: [
                    { label: 'Overview', link: '/core-packages/rust/nframework-core-template/overview/' },
                    { label: 'API Reference', link: '/core-packages/rust/nframework-core-template/api-references/' },
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
