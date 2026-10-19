# AutoOps+ AT0-001 Course Notes

Open course notes for the CompTIA AutoOps+ (AT0-001 V1) exam, written by
Dr. Frazier A. Smith for Central Piedmont's Network Programmability course and
published for anyone studying for the exam. Styled with the
[vfrazier.app](https://vfrazier.app) brand.

The notes follow the exam objectives in order. Each topic is a Markdown file,
and the build turns them into a two-column, print-ready PDF with a cover,
contents, domain dividers, figures, and PDF bookmarks.

## Status

Version 1.0.0 covers every objective in all four exam domains: 13 objectives in
38 topics, about 100 pages. The build produces the complete book and one PDF
per domain:

| File | Contents |
|---|---|
| `autoops-course-notes.pdf` | All four domains |
| `autoops-course-notes-domain-1.pdf` | 1.0 Automation Coding Concepts |
| `autoops-course-notes-domain-2.pdf` | 2.0 System Configuration |
| `autoops-course-notes-domain-3.pdf` | 3.0 Continuous Integration |
| `autoops-course-notes-domain-4.pdf` | 4.0 Continuous Delivery |

See [AUTHORING.md](AUTHORING.md) for how topics are written and tested.

## Every command is tested

Each command and output shown in the notes is exercised by a script in
`tests/`. CI runs them before building, so if a tool changes behavior the build
fails and the notes get fixed.

```sh
npm install
for t in tests/*.sh; do bash "$t"; done   # every command in the notes
npm run build                             # writes all PDFs to dist/
```

The tests use Docker, Terraform, Ansible, PowerShell, and other tools; each
script lists what it needs in a `# Needs:` comment, and
`.github/workflows/build.yml` installs the full set on a fresh runner. The build
uses Playwright's Chromium; locally, run `npx playwright install chromium` once.

## Writing a topic

Add a file under `content/domain-N/` and list it in `book.json` under a volume.

```markdown
---
objective: 1.3
title: Infrastructure as Code
---

### A subheading
- A bullet with a ==must-know term== in the yellow highlighter
  - A sub-bullet

:::figure wide my-diagram.svg | Caption text
:::exam
How this shows up on the exam.
:::
:::try Optional custom label
A short hands-on exercise.
:::
:::wide
| A table | that spans | both columns |
|---|---|---|
:::
```

Code fences take a label: ` ```console label="Terminal" `. In `console`
blocks, lines starting with `$ ` are commands and everything else is output.

Figures are hand-drawn SVGs in `figures/` using the brand palette.

## Brand

`styles/tokens.css` is copied verbatim from the vfrazier.app site repo, so
colors match the site exactly. Run `scripts/sync-tokens.sh` after changing the
site's palette. Type is Inter with IBM Plex Mono for code, both self-hosted.

## Releases

Push a tag such as `v1.0.0` and the workflow attaches the PDF to a GitHub
release. The notes themselves follow semantic versioning (see objective 1.2).

## License

Text and figures: [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/).
Build scripts and tests: MIT.

CompTIA and AutoOps+ are trademarks of CompTIA, Inc. This project is not
affiliated with or endorsed by CompTIA.
