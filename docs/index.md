# mirmid documentation

Entry point for the documentation of **mirmid**, a console AI-agent harness
written in Free Pascal. `README.md` is the user-facing overview; the notes here
describe how the program is built inside and where it is going. Start with the
map below and follow the note for your topic.

## Map

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | Layers, the turn loop, tool registry, sessions, MCP |
| [planning.md](planning.md) | Plan mode, `revise_plan`, step budgets, final report |
| [anthropic.md](anthropic.md) | The Anthropic Messages API client unit |
| [repository.md](repository.md) | Source tree, build targets, tests, conventions |
| [roadmap.md](roadmap.md) | Known gaps and next tasks, each tied to the code |

Reference material outside this directory:

- [../README.md](../README.md) — features, build on Windows and Linux, settings,
  `.mirmid` layout, MCP, license.
- [../AGENTS.md](../AGENTS.md) — rules for contributors: ground rules, build and
  test commands, verification steps, conventions.
- [../context.md](../context.md) — dated log of decisions, environment quirks,
  measured test counts and pitfalls. Read the section for your topic before
  changing code.
- [../config/mirmid.ini.example](../config/mirmid.ini.example) and
  [../config/mcp.json.example](../config/mcp.json.example) — reference settings
  files. `mirmid --init` writes a documented INI into `.mirmid/`.

## What each note contains

- **architecture.md** — the unit graph `mirmid.lpr` → `mirmid.cli` →
  `mirmid.agent` → `mirmid.llm` → `mirmid.http` → `mirmid.tlsclient` (with
  `mirmid.anthropic` as a standalone unit beside `mirmid.llm`, reached only
  from its tests), the model → tools → model turn cycle, the single tool
  registry and the `[tools]` policy, session files and the context journal,
  summarisation, the loop guard and the MCP stdio client.
- **planning.md** — plan mode (`--plan`, `[agent] plan=1`): preliminary
  analysis, one step per sub-session, the `revise_plan` operations, step
  iteration and retry budgets, the maximum number of steps and the final report.
- **anthropic.md** — scope of `src/mirmid.anthropic.pas`: request building and
  validation, regular and streaming responses, tools and error mapping. The unit
  is standalone; the agent loop talks to the OpenAI-compatible client today.
- **repository.md** — the `src/`, `tests/`, `config/`, `docs/` layout, what every
  unit is responsible for, the `Makefile` targets (`make`/`all`/`app`, `test`,
  `run`, `lazbuild`, `roots`, `tls-dir`, `win64`, `clean`), the fpcunit suite
  and its fixtures, and the coding conventions.
- **roadmap.md** — an honest list of gaps: only work that the current code shows
  as missing, each item pointing at the unit or setting involved.

## Reading paths

- **Build and run it:** `README.md` (Requirements, Build and test, Quick start).
- **Change a tool or the loop:** `architecture.md`, then the dated entries in
  `context.md`, then `repository.md` for tests and fixtures.
- **Work on plan mode:** `planning.md` plus `src/mirmid.plan.pas` and
  `src/mirmid.planner.pas`.
- **Pick up unfinished work:** `roadmap.md`, then `context.md`.

## Conventions for these notes

- English only. Text files are stored with LF endings (see `.gitattributes`).
- Statements must match the code: when a note and a unit disagree, the code is
  right — fix the note in the same change that touches the behaviour.
- User-visible behaviour changes go to `README.md` as well; decisions and
  measured results go to `context.md` with a date.
- Never document or commit local state: `.mirmid/` (settings, sessions,
  journals, logs), `bin/` and `build/` are git-ignored.
