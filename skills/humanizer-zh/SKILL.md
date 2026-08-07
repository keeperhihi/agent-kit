---
name: humanizer-zh
description: Edit Chinese prose to reduce clear AI-writing patterns while preserving meaning, facts, citations, structure, tone, and approximate length. Use only when the user explicitly invokes /humanizer-zh or explicitly requests Chinese humanization or removal of AI traces; do not use automatically for drafting, research, technical-document verification, or post-write review.
disable-model-invocation: true
---

# Humanizer-zh

Make Chinese text sound natural through minimal, evidence-based edits. Preserve the author's content rather than replacing it with a new composition.

## Editing contract

- Preserve every factual claim, qualification, citation, and explicit requirement.
- Do not add facts, opinions, examples, arguments, sections, or conclusions.
- Preserve headings, list structure, paragraph order, and document scope unless the user explicitly asks to restructure them.
- Preserve the original register. Technical and research writing should remain neutral and precise; do not inject first person, humor, emotion, or a manufactured personal voice.
- Do not change text solely to vary sentence length, alter the number of list items, remove a valid transition, or make the prose more quotable or less quotable.
- Treat tables, parallel lists, repeated labels, and concise technical patterns as functional structure, not AI evidence.
- Prefer deletion or a local substitution over expansion.

## Material patterns to fix

Edit a passage only when a pattern is clearly present and materially harms the text:

- inflated significance or unsupported claims about importance, legacy, or broad trends;
- promotional language where neutral description is expected;
- vague attribution such as "experts believe" without a source;
- empty meta-language, chatbot pleasantries, or generic optimistic conclusions;
- repetitive formulae such as repeated "not only ... but also ..." constructions;
- excessive filler, hedging, abstract nouns, or stacked transitions that obscure the claim;
- mechanical overuse of bold text, decorative emoji, or em dashes;
- invented analysis appended to otherwise factual sentences.

Common words, three-item lists, similar sentence lengths, and orderly structure are not defects by themselves.

## Workflow

1. Determine the exact text the user asked to humanize. Do not expand the scope.
2. Identify concrete passages that match a material pattern above.
3. Rewrite only those passages with the smallest change that resolves the issue.
4. Perform one read-only check that meaning, facts, citations, headings, lists, and formatting remain intact.
5. Stop. Do not run another style review or score-and-rewrite loop.

If no material pattern is present, return the text unchanged and say that no changes were necessary. A no-op is a successful result.

## Change budget

- Keep the revised text at or below the original word count by default.
- Permit small growth only when grammar requires it or the user explicitly asks for elaboration.
- Do not add or remove headings or list items without explicit authorization.
- Complete at most one rewrite pass per request.

## Output

Return the revised text. Optionally summarize only the material edits actually made. Do not provide a style score or a list of hypothetical improvements.

## Example

Before:

> 新的软件更新作为公司致力于创新的证明。此外，它提供了无缝、直观和强大的用户体验，彰显了公司在不断演变的技术格局中的关键作用。

After:

> 软件更新增加了批处理、键盘快捷键和离线模式。

The revision removes unsupported promotional claims and keeps the concrete information. It does not add a new argument or restructure surrounding content.

## Reference

Pattern guidance is adapted from [Wikipedia:Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing). Treat those patterns as diagnostic hints, never as mandatory rewrite targets.
