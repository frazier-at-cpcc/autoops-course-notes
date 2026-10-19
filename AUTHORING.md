# Authoring Guide

How to write a topic for the AutoOps+ course notes so it matches the rest of the
series. The objective 1.2 files in `content/domain-1/` are the reference
examples; read them before writing anything.

## Voice

The notes follow the study-guide format of short bullet fragments, not prose.

- Top-level bullets state a fact or concept in a few words. Sub-bullets add the
  detail, an example, or the consequence. Two levels, never three.
- Write fragments, not full sentences, except inside callouts.
- Every sentence is original. Do not paraphrase CompTIA CertMaster, Professor
  Messer, vendor docs, or any other study guide.
- Concrete over generic: name the real flag, the real error text, the real file.
- Examples come from IT operations and networking: switches, VLANs, DNS zones,
  Terraform modules, Ansible playbooks, CI pipelines.

Never use any of these:

- Em dashes. Use a colon, a semicolon, parentheses, or two sentences.
- "It's important to note", "it's worth mentioning", "plays a vital role",
  "serves as", "stands as", "testament to", "underscores", "in summary",
  "in conclusion", "overall".
- "Not only ... but also", "it's not just X, it's Y".
- Promotional adjectives: "powerful", "robust", "seamless", "cutting-edge".
- Vague attributions: "experts say", "many teams find".
- Emojis.

## Topic file

One Markdown file per topic under `content/domain-N/`, named
`<objective>-<slug>.md`, for example `1.3-iac-principles.md`.

```markdown
---
objective: 1.3
title: Infrastructure as Code Principles
---

### First subheading
- Bullet
  - Sub-bullet
```

- `title` is Title Case and appears in the purple topic bar, the contents page,
  and the PDF bookmarks.
- Use `###` for subheadings. Each topic has 3 to 7 of them.
- Target 1.5 to 2.5 printed pages per topic.
- Cover every leaf term the objective lists. Use the objective's own wording
  for the term somewhere on the page so a student can match it to the
  objectives PDF.

## Markup

| Need | Syntax |
|---|---|
| Must-know term (yellow highlighter) | `==term==` |
| Inline command, file, flag | `` `git fetch` `` |
| Terminal session | a ` ```console label="Terminal" ` fence; lines starting with `$ ` are commands, the rest is output |
| File contents | a ` ```yaml label="playbook.yml" ` fence (any language highlight.js knows) |
| Figure in one column | `:::figure my-figure.svg \| Caption` |
| Figure across both columns | `:::figure wide my-figure.svg \| Caption` |
| Table across both columns | wrap the table in `:::wide` and `:::` |
| Exam tips (end of every topic) | `:::exam` ... `:::` |
| Hands-on exercise | `:::try` ... `:::` or `:::try Custom Label` |

Highlighter rules: 2 to 5 `==terms==` per subheading, only for vocabulary the
exam expects a student to recognize. Never highlight a whole sentence.

Tables: keep them to 2 to 4 columns. A table that needs more than about 45
characters per row goes in `:::wide`.

Every topic ends with one `:::exam` callout of 2 or 3 bullets describing how
the topic shows up in a question: the scenario wording, the distractor, the
distinction being tested.

## Code and output must be real

Every code block and every line of terminal output in the notes is produced by
a test script before it is published.

- Put the script in `tests/<objective>-<slug>.sh`. It must be self-contained:
  `set -euo pipefail`, work in `mktemp -d`, clean up with `trap`, never touch
  the user's real config (`export GIT_CONFIG_GLOBAL=...` and the like), and end
  by printing `ALL <objective> <SLUG> CHECKS PASSED`.
- Assert the specific output the notes show (`grep -q`, exact comparisons), so a
  tool changing its behavior fails the build.
- Console output in the notes is copied from a real run. You may trim lines
  (drop noise, shorten a path), but never retype or "improve" output.
- When something cannot be executed here (a WinRM session to a Windows host, a
  real AWS apply), do not put it in a code block as if it ran. Either validate
  it statically and say so in the test (`terraform validate`,
  `ansible-playbook --syntax-check`, `actionlint`, `gitlab-ci-local --preview`)
  or present it as a table or bullets.
- Tests may use Docker containers, Terraform, OpenTofu, Ansible, PowerShell
  (`pwsh`), Python, Node, jq, yq, actionlint, act, and gitlab-ci-local. State
  any new tool at the top of the script in a `# Needs:` comment.
- Bind any local service to `127.0.0.1` on a port in your assigned range and
  give containers a unique name prefix, so tests can run in parallel.

## Figures

Figures are hand-drawn SVG in `figures/`, named `<objective>-<slug>.svg`.

- viewBox width 760 for wide figures, 360 for single-column figures.
- Palette only: ink `#1a1209`, muted `#5c4a30`, purple `#6d28d9`, deep purple
  `#3a1d70`, lavender `#efe6ff`, light purple `#c4b3ff`, yellow `#ffd60a`, pale
  yellow `#fffae0`, white `#fff`, rust accent `#9a3412`, rule `#d8d2c8`.
- Brand motifs: 2px ink strokes on boxes, solid offset shadows (draw a second
  ink rect offset by 2.5 units behind the box), rounded corners `rx="7"`.
- Text uses the page fonts automatically (Inter). Add `class="mono"` for
  commands. Font sizes 9 to 14 in viewBox units.
- No symbol glyphs such as check marks or arrows from fonts; draw them as
  paths. Font fallback for those glyphs embeds an ugly Type 3 font.
- Leave space: text must not touch or overflow its box. Render the page and
  look.
- Draw a figure when it shows a mechanism (flow, sequence, relationship). Do
  not draw a figure that only restates a list.

## Build and check

```sh
node scripts/build.mjs <volume>     # volumes are defined in book.json
pdftoppm -r 80 -png dist/<file>.pdf /tmp/page
```

Look at every page you produced. Check for text overflowing figures or tables,
columns left empty, a lone heading at the bottom of a column, and code lines
wrapping badly (keep code lines under about 52 characters so they fit a
column).
