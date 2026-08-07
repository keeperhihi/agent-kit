---
name: research
description: Gather primary-source evidence into a standalone cited Markdown research memo. Use only when the user explicitly invokes /research to delegate reading legwork and save a research artifact; do not use for ordinary web lookups, final user-facing document drafting, or post-write review or restructuring.
disable-model-invocation: true
---

# Research

Create a source artifact for later use. The research memo is evidence, not a polished final deliverable.

## Ownership

- Delegate the research to exactly one background agent.
- Make that agent the sole writer of the memo. The primary agent must not draft, edit, or review the same file while the background agent is working.
- Do not independently analyze the memo's subject or steer the writer toward extra coverage while it works. Wait unless the writer reports a concrete blocker.
- Work concurrently only on tasks independent of the memo.
- If the user explicitly asks to update an existing memo, keep the same single-writer rule. Otherwise create a new memo rather than reviewing or restructuring an existing document.

## Research requirements

1. Answer the stated question against primary sources: official documentation, source code, specifications, papers, or first-party APIs.
2. Trace material claims to the source that owns them. Separate sourced facts from inferences.
3. Write one concise Markdown memo with citations. Follow the repo's existing research-note convention; if none exists, choose a sensible location and report it.
4. Stay within the user's requested scope. Do not add adjacent topics merely to make the memo feel comprehensive.
5. Treat sources named as the basis of the question as a closed boundary. Phrases such as "documented in", "according to", "基于", or "参照" close the source set even when the user does not say "only". Do not add external standards, analogous products, definitions, or corroborating examples unless the user explicitly asks to broaden the research.
6. If the supplied sources are insufficient, state the limitation instead of searching beyond them.
7. Keep search caches, downloads, scratch notes, and intermediate drafts outside the repo. Before handoff, the worktree may contain only the requested memo and other files the user explicitly authorized.

## Verification and stopping

After the writer finishes, the primary agent may perform one read-only verification pass. A finding is `must_fix` only when it is one of:

- a verifiable factual error;
- a citation that does not support its claim;
- a broken required link;
- an internal contradiction;
- an explicit user requirement that is missing.
- an unexpected repository artifact created by the research process.

Style preferences, possible extra sources, alternative structures, and optional coverage are not defects. Report them only if useful; never apply them automatically.

If no `must_fix` issue exists, make no changes. A no-findings result is successful.

If a `must_fix` issue exists, send one correction request to the same writer. Allow at most one correction pass and do not dispatch another reviewer. Corrections must not add sections or increase the memo's length except where required to fix the issue or add its citation.

Do not invoke a humanizer, polishing, rewriting, or restructuring skill unless the user explicitly requests that separate operation.

## Handoff

Tell the user where the memo was saved and summarize the answer briefly. Do not turn verification into another writing phase.
