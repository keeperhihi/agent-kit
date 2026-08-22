---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

Use /tdd for behavior changes at a public seam. For documentation-only or
non-behavioral changes, do not invent a TDD cycle.

Run targeted checks for the behavior you changed. Do not run the full suite by
default or repeat passing checks. Run the full suite only when an explicit
project requirement applies or a shared interface has consumers you cannot
reasonably enumerate.

Once done, use /two-axis-review only when the user, the spec, or a project
review convention calls for a formal review. Otherwise perform a focused
self-review.

Commit your work to the current branch.
