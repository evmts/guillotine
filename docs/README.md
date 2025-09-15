# Guillotine Docs

Minimal, functional documentation. No sales, no fluff.

## Develop locally

Prereqs: [Bun](https://bun.sh)

```bash
cd docs
bun install
bun run dev
```

Build/preview:

```bash
bun run build
bun run preview
```

## Structure

Content lives in `pages/` as MDX. Keep pages short and task-oriented.

Current pages:
- `/` homepage (quick start + core commands)
- `/examples` minimal code samples
- `/faq` short answers to build/runtime questions
- `/status` alpha status and expectations
- `/roadmap` links to GitHub roadmap

## Writing guidelines

- Be precise and actionable; prefer commands over prose
- Remove marketing language; avoid unverifiable claims
- Ensure examples compile inside this repo
- Keep edits small and easy to review

For anything broader, open an issue first.

## Support

- **GitHub Issues** — Report documentation bugs or requests

## Links

- **GitHub Repository** - [evmts/Guillotine](https://github.com/evmts/Guillotine)
- **Live Documentation** - [guillotine.dev](https://guillotine.dev)
- **Vocs Documentation** - [vocs.dev](https://vocs.dev)

---

*This documentation is continuously updated as Guillotine evolves. The structure and tooling are designed to scale with the project's growth while maintaining excellent developer experience.*
