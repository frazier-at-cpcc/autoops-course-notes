# AutoOps+ AT0-001 Course Notes

Open course notes for the CompTIA AutoOps+ (AT0-001 V1) exam, written by
Dr. Frazier A. Smith for Central Piedmont's Network Programmability course and
published for anyone studying for the exam. Styled with the
[vfrazier.app](https://vfrazier.app) brand.

The notes follow the exam objectives in order. Each topic is a Markdown file,
and the build turns them into a two-column, print-ready PDF with a cover,
contents, domain dividers, figures, and PDF bookmarks.

## Status

Pilot release: objective 1.2 (source control) is complete. The remaining
objectives are listed as "coming soon" in the contents.

## Every command is tested

Each command and output shown in the notes is exercised by a script in
`tests/`. CI runs them before building, so if a tool changes behavior the build
fails and the notes get fixed.

```sh
npm install
npm test                        # 1.2 source control + semver checks
bash tests/1.2-precommit.sh     # needs pre-commit and network access
npm run build                   # writes dist/autoops-course-notes.pdf
```

The build uses Playwright's Chromium. Locally, run `npx playwright install chromium` once.

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
