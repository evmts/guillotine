import { defineConfig } from 'vocs/config'

export default defineConfig({
  title: 'Guillotine',
  titleTemplate: '%s · Guillotine',
  description:
    'Guillotine is an Ethereum Virtual Machine written in Zig, with a C ABI for embedding it in other languages.',
  rootDir: '.',
  baseUrl: 'https://guillotine.tevm.sh',
  logoUrl: {
    light: '/logo-light.svg',
    dark: '/logo-dark.svg',
  },
  iconUrl: '/favicon.svg',
  ogImageUrl:
    'https://og.tevm.sh/api/og?logo=%logo&title=%title&description=%description',
  font: {
    default: {
      google: 'Inter',
    },
    mono: {
      google: 'JetBrains Mono',
    },
  },
  topNav: [
    { text: 'Docs', link: '/', match: '/' },
    {
      text: 'Ecosystem',
      items: [
        { text: 'Tevm', link: 'https://tevm.sh' },
        { text: 'Test', link: 'https://test.tevm.sh' },
        { text: 'Bundler', link: 'https://bundler.tevm.sh' },
        { text: 'CLI', link: 'https://cli.tevm.sh' },
        { text: 'Ethers', link: 'https://ethers.tevm.sh' },
        { text: 'MUD', link: 'https://mud.tevm.sh' },
        { text: 'Examples', link: 'https://examples.tevm.sh' },
        { text: 'Voltaire', link: 'https://voltaire.tevm.sh' },
        { text: 'Guillotine', link: 'https://guillotine.tevm.sh' },
        { text: 'Mini', link: 'https://mini.tevm.sh' },
        { text: 'ZEVM', link: 'https://zevm.tevm.sh' },
      ],
    },
  ],
  sidebar: [
    {
      text: 'Guillotine',
      items: [
        { text: 'Overview', link: '/' },
        { text: 'Installation', link: '/installation' },
        { text: 'Getting started', link: '/getting-started' },
        { text: 'Project status', link: '/status' },
        { text: 'The stack', link: '/stack' },
        { text: 'Changelog', link: '/changelog' },
      ],
    },
    {
      text: 'Concepts',
      items: [
        { text: 'Architecture', link: '/concepts/architecture' },
        { text: 'Dispatch', link: '/concepts/dispatch' },
        { text: 'Synthetic opcodes', link: '/concepts/synthetic-opcodes' },
      ],
    },
    {
      text: 'Guides',
      items: [
        { text: 'Configuring the EVM', link: '/guides/configuration' },
        { text: 'State and journaling', link: '/guides/state' },
        { text: 'Tracing and debugging', link: '/guides/tracing' },
        { text: 'Testing and verification', link: '/guides/testing-and-verification' },
        { text: 'TigerStyle and safety guarantees', link: '/guides/tigerstyle' },
        { text: 'Benchmarks and native JIT', link: '/guides/benchmarks-and-jit' },
        { text: 'Language bindings', link: '/guides/bindings' },
        { text: 'Publishing and releases', link: '/guides/publishing' },
      ],
    },
    {
      text: 'Reference',
      items: [
        { text: 'Evm', link: '/reference/evm' },
        { text: 'Hardforks and EIPs', link: '/reference/hardforks' },
      ],
    },
    {
      text: 'Contributing',
      items: [{ text: 'Contributing', link: '/contributing' }],
    },
  ],
  editLink: {
    link: 'https://github.com/evmts/guillotine/edit/main/docs/src/pages/:path',
    text: 'Edit this page on GitHub',
  },
  socials: [
    { icon: 'github', link: 'https://github.com/evmts/guillotine' },
    { icon: 'telegram', link: 'https://t.me/+ANThR9bHDLAwMjUx' },
    { icon: 'x', link: 'https://x.com/tevmtools' },
  ],
  theme: {
    accentColor: {
      light: '#0085ff',
      dark: '#00c2ff',
    },
    colorScheme: 'system',
    variables: {
      color: {
        backgroundAccent: {
          light: '#0085ff',
          dark: '#00c2ff',
        },
        backgroundAccentHover: {
          light: '#0074e0',
          dark: '#3bc9db',
        },
        textAccent: {
          light: '#0085ff',
          dark: '#00c2ff',
        },
        link: {
          light: '#0085ff',
          dark: '#00c2ff',
        },
        linkHover: {
          light: '#0074e0',
          dark: '#3bc9db',
        },
      },
    },
  },
  markdown: {
    code: {
      themes: {
        light: 'github-light',
        dark: 'github-dark',
      },
    },
  },
})
