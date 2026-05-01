# LLM Wiki Schema

## Purpose
This repository is a persistent knowledge wiki.
The system compiles knowledge into markdown pages instead of rediscovering it from raw files every time.

## Directory Rules
- `raw/` is immutable source material. NEVER modify files in `raw/`.
- `wiki/` is maintained by the LLM.
- `wiki/index.md` is the master catalog of pages.
- `wiki/log.md` is append-only chronological history.
- `wiki/overview.md` is the high-level synthesis.

## Wiki Page Types
- `wiki/sources/` = per-source summaries
- `wiki/concepts/` = concepts, methods, themes
- `wiki/entities/` = people, orgs, tools, projects
- `wiki/comparisons/` = side-by-side analysis

## Ingest Workflow
When asked to ingest a source:
1. Read the file from `raw/`
2. Create or update a summary in `wiki/sources/`
3. Update related concept pages
4. Update related entity pages
5. Update `wiki/index.md`
6. Append a log entry to `wiki/log.md`
7. Preserve citations back to the source file

## Query Workflow
When asked a question:
1. Read `wiki/index.md` first
2. Open the most relevant wiki pages
3. Synthesize an answer with citations
4. If the answer is durable, propose saving it as a new wiki page

## Lint Workflow
When asked to lint:
1. Find contradictions
2. Find stale claims
3. Find orphan pages
4. Find missing cross-links
5. Suggest missing pages or missing sources

## Writing Conventions
- Use markdown only
- Prefer concise, factual writing
- Add internal links between related pages
- Keep claims traceable to source summaries
