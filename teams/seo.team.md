---
name: seo
description: "SEO audit service — technical SEO, content analysis, sitemap/link structure, reporting"
---

## Panes

| Pane | Role | Agent | Name | Model |
|------|------|-------|------|-------|
| 0 | manager | seo-manager | SEO Manager | opus |
| 1 | technical | seo-technical | Technical SEO | opus |
| 2 | content | seo-content | Content Analyst | opus |
| 3 | sitemap | seo-sitemap | Sitemap & Links | opus |
| 4 | reporter | seo-reporter | SERP Reporter | opus |

## Workflows

| Trigger | From | To | Subject |
|---------|------|----|---------|
| stop | technical | manager | technical_audit_complete |
| stop | content | manager | content_analysis_complete |
| stop | sitemap | manager | sitemap_analysis_complete |
| stop | reporter | manager | report_ready |

## Team Briefing

SEO audit service. The SEO Manager receives requests, classifies into modes (quick-audit, deep-audit, content-review, technical-check), dispatches to specialists, and returns prioritized findings.

- Technical SEO: sole browser operator — crawlability, robots.txt, canonicals, structured data, Core Web Vitals via Chrome DevTools MCP
- Content Analyst: title tags, meta descriptions, heading hierarchy, keyword usage, content quality from artifacts
- Sitemap & Links: sitemap.xml validation, internal links, broken links, redirect chains, orphan pages
- SERP Reporter: groups findings, prioritizes by SEO impact, produces action-ready reports

Only Technical SEO drives the live browser. All others consume artifacts.
