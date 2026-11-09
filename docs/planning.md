# Planning mode

Plan mode turns one user turn into four phases: a preliminary analysis, a plan,
the execution of every step in its own sub-session, and a final report. It is
implemented in `src/mirmid.plan.pas` (data model, JSON, rendering, report
helpers and prompts) and `src/mirmid.planner.pas` (`TPlanner`: the phase driver,
step retries and the `revise_plan` handler). The CLI creates one `TPlanner` for
the session, hands it the tool registry and registers `revise_plan` in that
registry; the plan itself lives in the parent session and is saved with it.

How it is switched on:

| Where | Setting |
| --- | --- |
| INI | `[agent] plan=1` |
| Command line | `--plan` / `--no-plan` |
| Environment | `MIRMID_PLAN` |
| REPL | `/plan` prints the current plan (or `no plan`) |

Related settings are read from `[agent]` in `mirmid.config`
(`plan_step_max_steps`, `plan_step_fix_attempts`, `plan_max_step`); the
`revise_plan` tool has its own key in `[tools]` and defaults to `1`.

## The four phases

### Phase 0 - preliminary analysis

A separate `TAgent` studies the task before any plan exists. Its config is a
copy of the parent config (`AnalysisConfig`) with the system prompt replaced by
`PLANNER_ANALYSIS_PROMPT`. Tool switches and every other setting are inherited
unchanged: the analysis works with exactly the tool set of the session, because
disabling tools "for safety" would silently refuse tools the user enabled. The
read-only rule comes from the prompt, not from the tool policy.

- History: the parent history without the system message, so the analysis sees
  the same dialogue as the main session.
- Budget: `[agent] max_steps`, the common agent budget (the step budget is
  separate, see below).
- While this phase runs the planner flag `FAnalyzing` is set and
  `revise_plan` refuses with `revise_plan is not available during the
  preliminary analysis`.
- The analysis session is written to `<session>_analysis.json` even when the
  turn failed, so the file shows where the agent stopped.
- On success `aeAnalysis` carries the text into the plan request. A failure is
  not fatal: the planner emits `aeError` (`preliminary analysis failed: ...`)
  and builds the plan without the analysis.

### Phase 1 - plan

The plan phase does not use an agent; it is one direct `TLLMClient.Chat` call
through `ChatLogged`, so the request/response pair lands in the model call log
with `phase=plan`.

Request messages: `PLANNER_SYSTEM_PROMPT`, the parent history without the
system message, then `BuildPlanPrompt(Task, Analysis)`. The model must answer
only with `{"steps": [{"description": "..."}]}`; descriptions are limited to
about 100 characters and each step must be one concrete action.

- `ExtractJSONBlock` accepts the first JSON object in the answer, including one
  inside a ```json fence or surrounded by prose; `ParsePlanFromText` then builds
  the plan.
- A parse failure is retried once: the failed answer is appended as an assistant
  message and a user message states the parse error and asks for JSON only. A
  second failure fails the phase and therefore the turn.
- `[agent] plan_max_step` > 0 truncates the plan with `TPlan.Truncate` and emits
  `aeError` (`the plan is truncated: the step limit is exceeded (N)`).
- Success replaces the previous plan, emits `aePlan` with `TPlan.Render`, and
  the CLI saves the session (the plan is part of the session JSON).
- `FPlanTask` remembers the task the plan was built for; step and report prompts
  use it on resumption instead of the latest instruction text.

### Phase 2 - steps

`RunPlannedTurn` loops while `TPlan.NextPending` finds a pending step:

1. The step becomes `in_progress`, `aeStepStart` fires (`s1: <description>`),
   and the session is saved.
2. `RunStep` creates a fresh `TAgent` with a copy of the parent config: the
   system prompt is `StepPrompt(task, plan, description, fixHint)` and
   `MaxSteps` is `[agent] plan_step_max_steps` (`0` - unlimited). The step itself
   is added as the user message, so the step asks for one step only and a short
   result.
3. The sub-session is labelled `step sN` in the status line and uses the file
   base `<session>_step_<id>`; retries add `_try<N>`. Subagents started inside
   the step inherit that base, so their files differ by attempt too.
4. The answer is classified by `ClassifyStepResult`:
   `sfNone` (a regular answer) sets the status `done` and stores a shortened
   result (`PLAN_STEP_RESULT_MAX` = 500 characters); `sfTurn` (`RunTurn`
   returned False), `sfEmpty` (blank answer) and `sfError` (text starting with
   `ERROR:`) set `failed` and keep the full reason for the retry prompt.
5. The attempt session is saved by `SaveStepSession`, and every attempt leaves
   log records in the model call log.

After a step ends, `aeStepEnd` carries the label `s1: done`, an em dash and the
result when non-empty; the CLI hides the result without `--show-step-result` or
`--show-reasoning`, and hides the task without `--show-step-task` or
`--show-reasoning`. A step removed by `revise_plan` during its own sub-cycle is
reported as `s1: removed from the plan`.

### Phase 3 - report

`ReportPhase` first builds a deterministic report with `BuildPlanReport`:
`Task: ...`, the rendered plan and `Summary: ...` (`3/5 done, 1 failed,
1 skipped`, only non-zero categories). That text is sent as the user message of
one more `ChatLogged` call with `REPORT_SYSTEM_PROMPT` and `phase=report`; the
model answer replaces the deterministic text and is emitted as `aeReport`.

A failed report request is not a failed turn: the error is cleared and the
deterministic summary is returned. The CLI appends the returned report to the
parent session as an assistant message.

The turn itself succeeds only when the plan has no `pending` and no
`in_progress` step left. Otherwise the planner returns `the plan still has steps
that did not reach a terminal state`, appends `; last step failure sN: <reason>`
when a step failed, and the CLI prints that error.

## Plan model

`TPlan` owns an array of `TPlanStep` records: `Id`, `Description`, `Status`,
`Result`. Ids are generated as `sN` (`s1`, `s2`, ...) when a step is added, so
they stay stable while steps are reordered, removed or added.

| Status | JSON name | Meaning |
| --- | --- | --- |
| `psPending` | `pending` | not started yet |
| `psInProgress` | `in_progress` | the current step, being executed |
| `psDone` | `done` | finished with a result |
| `psFailed` | `failed` | abnormal result; the reason is in `result` |
| `psSkipped` | `skipped` | skipped by `revise_plan` |

`ToJSON` writes `{"steps": [{"id": ..., "description": ..., "status": ...,
"result": ...}]}`; `FromJSON` parses it back and rejects an empty `steps` array,
an empty description, a duplicate id and an unknown status name, while an absent
id is generated as `sN` and an absent status becomes `pending`. The plan is
stored in the session as the `plan` field (session schema 2; a session without
the field simply has no plan). `Render` prints one line per step,
`N. [status] description - result`, and is what `aePlan`, `revise_plan` results
and the report are built on.

## Plan revision: `revise_plan`

`revise_plan` is registered by `RegisterRevisePlanTool` as a method tool bound to
the current `TPlanner`, so it always edits the live plan of the session. The
handler `HandleRevisePlan` accepts a single argument `ops`: an array of
operations that are applied in order.

| Operation | Fields | Effect |
| --- | --- | --- |
| `add` | `description` (required, non-empty), `after` (optional step id) | inserts a new step with a fresh `sN` id after `after`; an empty `after` appends at the end |
| `remove` | `id` | deletes the step |
| `reorder` | `order` (array of ids) | sets a new order; the id set must match the plan exactly |
| `skip` | `id` | sets `skipped`; only allowed for a `pending` step |

Validation and failure behaviour:

- The handler checks the `revise_plan` key of `[tools]` itself and answers
  `tool "revise_plan" is disabled`, because the planner also calls the handler
  directly (see below) without the registry.
- `no plan: revise_plan is available only in planning mode` when no plan
  exists; `the "ops" argument is required: an array of operations` and
  `empty "ops": at least one operation is required` for a malformed call.
- Operations are applied one by one; on an invalid operation the ones applied
  before it are kept and the tool returns an `ERROR:` text naming the operation
  number and the reason (unknown step, duplicate/missing id set, non-pending
  skip, non-object item, unknown `op`, empty `add` description, `plan_max_step`
  limit).
- A successful call emits `aePlan` with the rendered plan, saves the session and
  answers `plan updated: add s3 (...); skip s2`.
- `mcp__<server>__<tool>` tools cannot be revised and other tools are
  unaffected: the plan JSON is the only interface.

## Step budgets and retries

| Setting | Default | Effect |
| --- | --- | --- |
| `[agent] max_steps` | `0` | iteration budget of a normal turn and of the analysis phase |
| `[agent] plan_step_max_steps` | `0` | iterations of one plan step (`0` - unlimited) |
| `[agent] plan_step_fix_attempts` | `1` | retries of a step after an abnormal result |
| `[agent] plan_max_step` | `0` | maximum number of steps in a plan (`0` - unlimited) |

`StepMaxTries` returns `1 + plan_step_fix_attempts`: a negative or zero value
degenerates into a single attempt, the default gives two.

A failed step is repeated with `StepPrompt(..., fixHint)` where `fixHint` is the
previous failure reason, so the model fixes the situation instead of repeating
the failed call. A success clears the hint. When all attempts are exhausted and
the step is still `failed`, `ReviseAfterStepFailure` asks the model for a
decision with `STEP_REVISE_PROMPT` and expects JSON only:

- `{"decision": "revise", "ops": [...], "reason": "..."}` - the operations are
  applied by the very same `HandleRevisePlan` (one place for validation,
  `aePlan` and session saving; the `revise_plan` switch is enforced there too),
  and the work continues with the revised plan;
- `{"decision": "stop", "reason": "..."}` or an unclear answer - the turn stops:
  `aeError` with `step sN failed: <reason>; <why>` and the turn returns False
  without a report.

Two cases avoid a second revision attempt: when `revise_plan` inside the step
sub-cycle already removed the step or changed its status, the planner only logs
`... plan revision is not needed`; and a step that failed but is no longer
`failed` in the plan is not revised again.

## Resumption and interactive mode

A new plan is built only when there is no plan or when every step of the
previous one reached a terminal state (`done`, `failed`, `skipped`). An
incomplete plan (a `pending` or `in_progress` step) is resumed from the first
pending step with the remembered plan task.

`TPlanner.Interactive` is set for the REPL (and for `--interactive`). In that
mode a turn ends right after the plan phase: `FinalText` is the rendered plan
and the steps run on the next user instruction. A one-shot run (a prompt
argument without `--interactive`) executes plan, steps and report in the same
turn.

## Model call log and sessions

Every phase writes to the model call log of the session,
`./.mirmid/logs/<session>.jsonl` (`AppendModelLog`), with the phase label in the
`phase` field:

The messages below are exact code strings, except that the em dash (`U+2014`)
they contain is printed as `-` because this note is ASCII-only.

- `analysis` - analysis turns;
- `plan` - the plan request and its retry;
- `step sN try K/M` - a step attempt, plus `step sN try K/M result: ok|turn|
  empty|error`, `step sN try K/M: attempts exhausted` and
  `step sN try K/M: <state> - plan revision is not needed` records;
- `step sN revise` - the decision request after exhausted attempts;
- `report` - the final report request.

A log write failure never aborts a phase; the error is emitted as `aeError` and
the work continues.

Auxiliary sessions of the planner sit next to the main session and are hidden
from `--list-sessions`:

```text
.mirmid/sessions/<id>.json                  parent session, includes the plan
.mirmid/sessions/<id>_analysis.json         preliminary analysis
.mirmid/sessions/<id>_step_s1.json          first attempt of step s1
.mirmid/sessions/<id>_step_s1_try2.json     retry of step s1
```

## Extending planning mode

- Prompts are constants next to the code that uses them:
  `PLANNER_ANALYSIS_PROMPT`, `PLANNER_SYSTEM_PROMPT`, `BuildPlanPrompt`,
  `BuildStepPrompt` and `REPORT_SYSTEM_PROMPT` in `mirmid.plan`,
  `STEP_REVISE_PROMPT` in `mirmid.planner`. Untested prompt edits change model
  behaviour, so keep the JSON contract lines intact.
- New revision operations belong in `HandleRevisePlan` (validation, event,
  session save) and in the `ops` schema of `RegisterRevisePlanTool`; both the
  tool call and the decision path then support them at once.
- A new budget must be added to `TMirmidConfig`, read in `mirmid.config`,
  emitted by `--init`, documented in `README.md` and covered by a test in
  `tests/test_planner.pas` or `tests/test_plan.pas`.
- The planner never bypasses the registry for tool calls: step agents run the
  normal `TAgent` loop, so `[tools]`, MCP, the loop guard and summarisation keep
  working inside a step.
