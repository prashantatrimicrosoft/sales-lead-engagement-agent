# Agent Script backup — v3 (current)

Source: pasted directly from Agentforce Builder's Script view into VS Code
and saved as `.agentscript` — no RTF conversion involved, so this is the
cleanest export path so far.

**Confirmed via diff against the previous (v2, RTF-derived) backup:**
no functional changes. All differences were cosmetic — indentation width
(4-space here vs. wider tab-based indentation in v2) and one em dash vs.
hyphen character in Outreach Agent's description. Content, logic, actions,
and instructions are identical.

`raw-export/agent-script-full.agentscript` is the source of truth. Every
other file here is mechanically split from it via exact line-range
extraction (see line numbers below) — not retyped.

## Directory structure

```
agent-config/
├── raw-export/
│   └── agent-script-full.agentscript   ← verbatim, ground truth
├── agent-definition.agentscript         (lines 1-41: system/config/access/language/variables/knowledge)
├── subagents/
│   ├── agent-router.agentscript          (42-56)
│   ├── escalation.agentscript            (58-67)
│   ├── off-topic.agentscript             (69-88)
│   ├── ambiguous-question.agentscript    (90-110)
│   ├── research-agent.agentscript        (112-245)
│   ├── warm-path-agent.agentscript       (247-292)
│   └── outreach-agent.agentscript        (294-end)
└── actions/
    ├── find_account_news.agentscript          (145-173, within Research Agent)
    ├── find_account_by_name.agentscript        (174-196, within Research Agent)
    ├── find_relevant_case_study.agentscript    (197-245, within Research Agent)
    └── find_relationship_recency.agentscript   (264-292, within Warm-Path Agent)
```

## Known naming note (carried forward from v2)

`find_account_by_name`'s actual live label is `"find_account_by_name"`
(snake_case), not "Find Account By Name" — confirmed from the real export,
not a guess.

## Recommended export path going forward

VS Code paste → save as `.agentscript` (this method). Avoid RTF/TextEdit —
its RTF format requires a LibreOffice headless conversion step to preserve
indentation correctly (pandoc's plain-text writer strips it).

## Regenerating this split

1. Export fresh Script view text (Agent Definition → Script view → select
   all → copy) directly into a plain-text editor (VS Code, not TextEdit)
2. Save as `.agentscript`
3. Confirm section line numbers with:
   ```
   grep -n "^system:\|^config:\|^access:\|^language:\|^variables:\|^knowledge:\|^start_agent\|^subagent " <file>
   ```
4. Re-run the `sed` line-range extractions above, updating ranges if they've
   shifted.
