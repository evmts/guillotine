import { defineConfig } from 'vocs'

export default defineConfig({
  title: 'Guillotine',
  titleTemplate: '%s - Guillotine Docs',
  description: 'Minimal, functional docs for building, testing, and using the Zig EVM.',
  rootDir: '.',
  baseUrl: 'https://guillotine.dev',
  logoUrl: {
    light: '/logo-light.svg',
    dark: '/logo-dark.svg'
  },
  iconUrl: {
    light: '/favicon-light.ico',
    dark: '/favicon-dark.ico'
  },
  ogImageUrl: 'https://guillotine.dev/api/og?logo=%logo&title=%title&description=%description',
  
  // Enhanced font configuration for better readability
  font: {
    default: {
      google: 'Inter'
    },
    mono: {
      google: 'JetBrains Mono'
    }
  },
  
  // Minimal top navigation
  topNav: [
    { text: 'Docs', link: '/', match: '/' },
    { text: 'Examples', link: '/examples', match: '/examples' },
  ],
  
  // Edit link for contributions
  editLink: {
    pattern: 'https://github.com/evmts/Guillotine/edit/main/docs/pages/:path',
    text: 'Edit this page on GitHub'
  },
  // Minimal sidebar with existing pages only
  sidebar: [
    { text: 'Overview', items: [
      { text: 'Home', link: '/' },
      { text: 'Architecture', link: '/architecture' }
    ] },
    { text: 'Resources', items: [
      { text: 'Examples', link: '/examples' },
      { text: 'Memory', link: '/memory' },
      { text: 'Compatibility', link: '/compatibility' },
      { text: 'FAQ', link: '/faq' },
      { text: 'Status', link: '/status' },
      { text: 'Roadmap', link: '/roadmap' },
    ] },
  ],
  socials: [ { icon: 'github', link: 'https://github.com/evmts/Guillotine' } ],
  
  // Professional theme configuration inspired by Stripe & Vercel
  theme: {
    accentColor: {
      light: '#EA580C',  // Orange-600
      dark: '#FB923C'    // Orange-400
    },
    colorScheme: 'system',
    variables: {
      color: {
        background: {
          light: '#FFFFFF',
          dark: '#0A0A0A'
        },
        background2: {
          light: '#FAFAFA',
          dark: '#141414'
        },
        background3: {
          light: '#F5F5F5',
          dark: '#1F1F1F'
        },
        backgroundAccent: {
          light: '#EA580C',
          dark: '#FB923C'
        },
        backgroundAccentHover: {
          light: '#DC2626',
          dark: '#FED7AA'
        },
        heading: {
          light: '#111111',
          dark: '#FAFAFA'
        },
        text: {
          light: '#404040',
          dark: '#A3A3A3'
        },
        text2: {
          light: '#666666',
          dark: '#888888'
        },
        border: {
          light: '#E5E5E5',
          dark: '#262626'
        },
        codeBlockBackground: {
          light: '#FAFAFA',
          dark: '#0A0A0A'
        },
        codeInlineBackground: {
          light: '#F3F4F6',
          dark: '#1F2937'
        },
        link: {
          light: '#EA580C',
          dark: '#FB923C'
        },
        linkHover: {
          light: '#DC2626',
          dark: '#FED7AA'
        }
      },
      fontFamily: {
        default: '"Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif',
        mono: '"JetBrains Mono", "SF Mono", Monaco, "Inconsolata", "Fira Code", monospace'
      },
      fontSize: {
        root: '16px',
        h1: '2.5rem',
        h2: '2rem',
        h3: '1.5rem',
        h4: '1.25rem',
        h5: '1.125rem',
        h6: '1rem',
        code: '0.875rem',
        codeBlock: '0.875rem'
      },
      lineHeight: {
        heading: '1.2',
        paragraph: '1.75',
        code: '1.5'
      },
      content: {
        width: '1280px',
        horizontalPadding: '2rem',
        verticalPadding: '3rem'
      },
      borderRadius: {
        '0': '0',
        '2': '0.125rem',
        '4': '0.25rem',
        '8': '0.5rem'
      }
    }
  },
  
  // Search configuration for better discoverability
  search: {
    boostDocument(documentId) {
      if (documentId.includes('examples')) return 1.5
      return 1
    }
  },
  
  // Markdown enhancements
  markdown: {
    code: {
      themes: {
        light: 'github-light',
        dark: 'github-dark'
      }
    }
  },
  
  // Banner for alpha warning
  banner: {
    dismissable: true,
    backgroundColor: '#FEF3C7',
    textColor: '#92400E',
    content: '⚠️ **Alpha Release**: Guillotine is in early development and NOT suitable for production use. [Learn more →](/status)'
  }
})
