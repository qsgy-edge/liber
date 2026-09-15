# Domain Docs

Before exploring, read the relevant files when they exist:

- `CONTEXT.md`
- `CONTEXT-MAP.md`
- Relevant ADRs under `docs/adr/`
- Context-specific ADRs under `src/<context>/docs/adr/`

Proceed silently when these files do not exist. Create them lazily through the domain-modeling workflow.

This repo uses the single-context layout:

/
├── CONTEXT.md
├── docs/adr/
└── src/

Use terminology defined in `CONTEXT.md`. Surface conflicts with existing ADRs explicitly rather than silently overriding them.
