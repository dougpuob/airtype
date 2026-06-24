# Web UI styles

`app.css` is the only stylesheet loaded by `index.html`.

- `foundation.css`: tokens, resets, reusable controls, and settings primitives.
- `transcript-layout.css`: transcript/player/history layout and its visual rules.
- `workspace-layout.css`: shared workspace refinements and Post Weaver layout.
- `dashboard-layout.css`: current application shell and responsive overrides.

Import order is intentional: these files preserve the existing cascade while
making future changes land beside the view they affect. New page-specific rules
should go in a dedicated `*-layout.css` file imported after `foundation.css`.
