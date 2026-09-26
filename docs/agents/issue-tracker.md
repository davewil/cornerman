# Issue tracker: Linear

Issues for Cornerman live in Linear. Use the **Linear MCP server** for every operation. If its
tools are deferred, load them in **one** `ToolSearch` call. This follows beam-sharp's convention
(`~/dev/misc/beam-sharp/docs/agents/issue-tracker.md`), trimmed to what this repo uses.

## Team and project

**Team: `Engineering` (key `ENG`). Project: `cornerman`**, exact string. A wrong project name
returns an empty list and raises no error.

- Project: <https://linear.app/davewil/project/cornerman-6299cc8cf798>
- Map (index issue): [ENG-473](https://linear.app/davewil/issue/ENG-473), label `wayfinder:map`

## Canonicality is split

Linear owns **state**: status, assignee, blocking, labels, the frontier. The repo owns
**content**: `docs/plan.html`, `DIVERGENCES.toml`, code and tests. An issue description carries
the gist and points at the repo; never paste a plan section into Linear as a second copy.

## What lives there

| Kind | Label | State | Notes |
|---|---|---|---|
| Phase | `Feature` | Backlog → In Progress → Done | Sub-issue of ENG-473. Each phase is blocked by the one before it through native relations. The description's **Done when** line is the acceptance test. |
| Open decision | `wayfinder:grilling` + `ready-for-human` | Todo | David's call. An agent never answers it. Each one blocks the phase that needs the answer. |
| Deferral | `deferred` | Backlog | The body holds the revisit trigger and what the option would need. Check the trigger has fired before picking one up. |
| After-parity work | `Improvement` | Backlog | Blocked by the phase that makes it possible. |
| Upstream drift item | `Improvement` | Triage | Sub-issue of ENG-473, filed by the bump job (decided in ENG-483). The title names the upstream SHA range; the body lists the failing conformance cases or the new surface with no case. |

## Conventions

- **Create**: `save_issue` with `team: "Engineering"`, `project: "cornerman"`, `parentId: "ENG-473"`.
- **Update**: `save_issue` with `id` set to the identifier. Prefer `patch` over rewriting a
  description. Use `addLabels`/`removeLabels`, because `labels` replaces the whole set.
- **Blocking**: native `blockedBy`/`blocks` relations, never a `Blocked by:` line in prose.
- **Claim** before starting: `state: "In Progress"`, `assignee: "me"`.
- **Close a phase**: commit the work, confirm the **Done when** line against the commit, add a
  comment naming the commit SHA and the evidence, then set `state: "Done"`.
- **Record a decision**: when a `wayfinder:grilling` issue is answered, write the answer into its
  description, close it, and append one dated line to ENG-473's *Decisions so far*
  (`patch`, `insert_after` the last entry).
- Identifiers come from Linear. Never compute one from another.
