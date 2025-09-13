# Guillotine Documentation

This directory contains the comprehensive documentation for Guillotine, the ultrafast Ethereum Virtual Machine (EVM) implementation written in Zig. The documentation is built using [Vocs](https://vocs.dev), a modern documentation framework optimized for developer experience.

## 📁 Documentation Structure

The documentation is organized into the following sections:

### 🚀 Getting Started (`/getting-started`)
- **Installation** - System requirements and installation instructions
- **Quick Start** - Get up and running in minutes
- **Basic Example** - Your first Guillotine program

### 📖 Usage (`/usage`)
- **Basic Execution** - Core EVM execution patterns
- **Configuration** - Runtime and compile-time configuration
- **Error Handling** - Error types and handling strategies

### 📝 API Reference (`/api`)
- **EVM** - Core EVM API documentation
- **State** - State management and persistence
- **Types** - Type definitions and data structures

### 📦 SDKs (`/sdks`)
Language-specific bindings and SDKs:
- Go, Rust, Python, TypeScript, Bun, Swift, C

### 🔧 Advanced (`/advanced`)
In-depth technical documentation:
- **Language Bindings** - C API and language integration
- **Performance** - Benchmarks, optimization, and memory management
- **Customization** - Compile-time config, hardforks, opcodes, precompiles
- **Architecture** - System design, EVM core, bytecode analysis
- **Testing** - Unit tests, differential testing, fuzzing

### 🤝 Contributing (`/contributing`)
- **Development Setup** - Local development environment
- **Code Guidelines** - Coding standards and practices
- **Testing Requirements** - Testing strategies and requirements

### 📚 Resources
- **Examples** - Code samples and use cases
- **FAQ** - Frequently asked questions
- **Status** - Current development status
- **Roadmap** - Future development plans

## 🛠️ Building the Documentation

### Prerequisites

- [Bun](https://bun.sh) runtime
- Node.js (for compatibility)

### Development Server

Start the development server with hot reload:

```bash
cd docs
bun install
bun run dev
```

The documentation will be available at `http://localhost:5173`

### Production Build

Build the documentation for production:

```bash
bun run build
```

The built documentation will be output to the `dist/` directory.

### Preview Production Build

Preview the production build locally:

```bash
bun run preview
```

## 🔧 Documentation Tools

### Vocs Configuration

The documentation is configured via `vocs.config.ts`, which includes:

- **Theme Configuration** - Custom orange accent color scheme with light/dark mode
- **Navigation Structure** - Top navigation and comprehensive sidebar
- **Search Integration** - Built-in search with document boosting
- **Social Links** - GitHub, Telegram, Discord, X (Twitter)
- **Edit Links** - Direct GitHub editing integration
- **Typography** - Inter font with JetBrains Mono for code

### Content Format

Documentation is written in **MDX** (Markdown with JSX), allowing for:

- Standard Markdown syntax
- React components for interactive elements
- Code syntax highlighting
- Embedded examples and demos

### Deployment

The documentation is automatically deployed to Vercel:

- **Production**: `https://guillotine.dev`
- **Preview**: Auto-deployed for pull requests
- **Build**: Uses optimized Bun-based build process

## 📝 Writing Documentation

### File Structure

All documentation files are located in `pages/` directory:

```
pages/
├── index.mdx                 # Homepage
├── getting-started/          # Getting started guides
├── usage/                    # Usage documentation  
├── api/                      # API reference
├── sdks/                     # SDK documentation
├── advanced/                 # Advanced topics
├── contributing/             # Contribution guides
├── examples.mdx              # Examples
├── faq.mdx                   # FAQ
├── roadmap.mdx               # Roadmap
└── status.mdx                # Development status
```

### Adding New Pages

1. Create a new `.mdx` file in the appropriate directory
2. Add frontmatter with title and description:
   ```mdx
   ---
   title: Page Title
   description: Page description for SEO
   ---
   ```
3. Update `vocs.config.ts` to include the new page in navigation
4. Test locally with `bun run dev`

### Style Guidelines

- Use clear, concise language
- Include code examples where applicable
- Follow the existing structure and formatting
- Test all code examples before committing
- Use consistent terminology throughout

## 🔍 Search Optimization

The documentation includes advanced search features:

- **Document Boosting** - Important sections rank higher
- **Full-text Search** - Searches all content including code blocks
- **Keyboard Navigation** - Quick search with `/` key

## 🎨 Theme and Branding

The documentation uses a professional theme inspired by modern developer tools:

- **Colors** - Orange accent (`#EA580C` light, `#FB923C` dark)
- **Typography** - Inter for text, JetBrains Mono for code
- **Layout** - Responsive design with optimal reading width
- **Components** - Custom components for callouts, buttons, and layouts

## 🚨 Alpha Status Banner

A dismissible banner warns users about the alpha status and directs them to the status page for current limitations and known issues.

## 📊 Analytics and Monitoring

The documentation includes:

- Performance monitoring via Vercel analytics
- Search query tracking for content optimization
- Page view metrics for prioritizing updates

## 🤝 Contributing to Documentation

1. **Fork** the repository
2. **Create** a feature branch for your documentation changes
3. **Write** clear, helpful content following existing patterns
4. **Test** locally with `bun run dev`
5. **Submit** a pull request with a clear description

### Documentation Standards

- All code examples must be tested and working
- Include both basic and advanced examples where relevant
- Update navigation in `vocs.config.ts` for new sections
- Follow the existing tone and style
- Link to related sections where helpful

## 📞 Support

For questions about the documentation:

- **GitHub Issues** - Report documentation bugs or requests
- **Discord** - Join the community for help
- **Telegram** - Real-time community support

## 🔗 External Links

- **GitHub Repository** - [evmts/Guillotine](https://github.com/evmts/Guillotine)
- **Live Documentation** - [guillotine.dev](https://guillotine.dev)
- **Vocs Documentation** - [vocs.dev](https://vocs.dev)

---

*This documentation is continuously updated as Guillotine evolves. The structure and tooling are designed to scale with the project's growth while maintaining excellent developer experience.*