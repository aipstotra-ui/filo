# System map

One page showing how the whole thing fits together: who does the work, what the
documents are for, and how a file travels through the app. Diagrams render in
Obsidian and on GitHub.

---

## 1. The agent workflow

The founder speaks only to the main session. The main session is tech lead, and
the only thing that can start an agent.

```mermaid
flowchart TB
    F([👤 Founder / CEO]) <-->|plain language only| TL[["🎯 Main session — tech lead<br/>the only orchestrator"]]

    TL --> GATE{Scope gate<br/>big or small?}
    GATE -->|small: bug, copy, refactor| LIGHT["⚡ Lightweight path<br/>tech lead does it directly<br/>+ only the 1–2 reviewers that apply"]
    GATE -->|milestone, user files,<br/>AI path, or move/undo| P1

    subgraph PIPE ["Full pipeline — run unprompted for every milestone"]
        direction TB
        P1["1 · planner<br/>steps, risks, edge cases"]
        P2["2 · ui-designer + a11y-architect<br/>HTML mockup + accessibility spec"]
        APV{{"✋ Founder approves the mockup<br/>the only mid-pipeline touchpoint"}}
        P3["3 · tdd-guide → swift-builder<br/>tests first, then code"]
        BR["swift-build-resolver<br/>only if the build breaks"]
        P4["4 · qa-tester<br/>swift test = hard gate"]
        P5["5 · REVIEW ROUND — all in parallel"]
        P6["6 · code-simplifier<br/>clarity, behaviour preserved"]
        P7["7 · ui-designer + a11y-architect<br/>does the build match the design?"]
        P8["8 · docs-keeper<br/>docs, open-work, learnings"]

        P1 --> P2 --> APV --> P3 --> P4 --> P5
        P3 -.-> BR -.-> P3
        P5 --> P6 --> P7 --> P8
    end

    subgraph REV ["Review lanes — report only, never edit"]
        direction LR
        R1["code-critic<br/>data loss"]
        R2["swift-reviewer<br/>Swift idiom"]
        R3["silent-failure-hunter<br/>swallowed errors"]
        R4["security-auditor<br/>privacy promise"]
        R5["ai-reviewer<br/>AI diffs only"]
        R6["database-reviewer<br/>SQLite diffs only"]
        R7["a11y-architect<br/>UI only"]
    end

    P5 <--> REV
    REV -->|every finding, same turn| OW[("📋 open-work.md<br/>the one list")]
    P5 -->|fixes| P3
    P8 --> COMMIT["✅ Commit<br/>then STOP and check in"]
    COMMIT --> F
    LIGHT --> OW

    style F fill:#0A84FF,stroke:#0A84FF,color:#fff
    style TL fill:#1c1c1e,stroke:#0A84FF,color:#fff
    style APV fill:#FFB340,stroke:#C93400,color:#000
    style OW fill:#D70015,stroke:#D70015,color:#fff
    style COMMIT fill:#30D158,stroke:#248A3D,color:#000
    style GATE fill:#5E5CE6,stroke:#5E5CE6,color:#fff
```

**Read it as:** everything funnels through the tech lead. The scope gate decides
whether a change earns the full pipeline. Reviewers can only *report* — they
cannot edit, so no judgement call gets buried. Every finding lands in
[[open-work]] the moment it arrives.

---

## 2. The documents, and what each is for

```mermaid
mindmap
  root((📁 The vault))
    CLAUDE.md
      always loaded, every turn
      keep it small
      rules + pointers only
    README.md
      for a human arriving cold
    docs/00-Overview.md
      the map — start here
    📋 open-work.md
      THE ONE LIST
      blocking defects
      founder's queue
      deferred on purpose
      release checklist
    product/
      what we are building
        architecture.md
          the pipeline, in words
        milestones.md
          what shipped, M1 to M6
        decisions.md
          why — never re-litigate
        design-system.md
          how it looks
        modules/
          one note per code folder
          Watcher
          Extraction
          AI-Engine
          Folder-Index
          Popup-UI
          History-Undo
    process/
      how we build it
        workflow.md
          the pipeline + scope gate
        agent-roster.md
          who's who
        system-map.md
          this page
        engineering-rules.md
          always-on standards
        ai-engineering.md
          safe local-model integration
        learnings.md
          lessons, never relearn
    milestone-work/
      scratch, one folder per milestone
      distil out when it closes
      m6/
    mockups/
      HTML the founder approves
    website/
      separate track
      never mixed with the app
      Web-Team-Playbook.md
```

### The rule that keeps it clean

**Root of `docs/` = the map and the open list. Nothing else.** Anything tied to
one milestone goes in `docs/milestone-work/<milestone>/`, and when that milestone
closes its durable facts are **distilled out** into the permanent homes above.

> A fact that exists only in a closed milestone's scratch folder is **lost** —
> nobody reads a finished milestone's working notes.

---

## 3. Which document answers which question

```mermaid
flowchart LR
    Q1["What should I<br/>work on?"] --> A1[["open-work.md"]]
    Q2["Why is it<br/>built this way?"] --> A2[["decisions.md"]]
    Q3["What already<br/>works?"] --> A3[["milestones.md"]]
    Q4["How do I run<br/>the team?"] --> A4[["workflow.md"]]
    Q5["How does this<br/>module work?"] --> A5[["product/modules/*"]]
    Q6["Have we hit this<br/>bug before?"] --> A6[["learnings.md"]]
    Q7["What does the<br/>code style demand?"] --> A7[["engineering-rules.md"]]
    Q8["What should it<br/>look like?"] --> A8[["design-system.md"]]

    style A1 fill:#D70015,stroke:#D70015,color:#fff
```

---

## 4. How a file travels through the app

The code mirrors this exactly — one folder under `Sources/FileOrganizer/` per
box, one note in `docs/product/modules/` per folder.

```mermaid
flowchart LR
    D[/"📥 New file lands<br/>in ~/Downloads"/] --> W

    W["Watcher<br/>waits until it's<br/>really finished"]
    E["Extraction<br/>reads what's inside<br/>PDF · OCR · text"]
    A["AI-Engine<br/>on-device model →<br/>summary + name"]
    I["Folder-Index<br/>which folder<br/>fits best?"]
    P["Popup-UI<br/>shows the suggestion"]
    H["History-Undo<br/>the ONLY code that<br/>touches your files"]

    W --> E --> A --> I --> P
    P -->|"✋ user accepts —<br/>nothing moves without this"| H
    H --> FS[("💾 File moved<br/>+ undoable row")]
    P -->|dismiss / ignore| NOTHING(["nothing happens"])

    NET>"🚫 zero network calls<br/>anywhere in this chain"]

    style H fill:#D70015,stroke:#D70015,color:#fff
    style NET fill:#30D158,stroke:#248A3D,color:#000
    style P fill:#0A84FF,stroke:#0A84FF,color:#fff
```

**Three invariants** the whole product rests on:

1. **Zero network calls.** The model ships with macOS; there is nothing to
   download. Any networking is a critical review finding.
2. **Nothing moves without an explicit accept.**
3. **Only History-Undo mutates a file**, so every change is recorded and
   reversible.

---

## 5. The two teams

```mermaid
flowchart TB
    F([👤 Founder]) --> TL[["🎯 Main session<br/>orchestrates both"]]

    TL --> ENG
    TL --> WEB

    subgraph ENG ["⚙️ Engineering team → the macOS app"]
        direction LR
        E1["builders<br/>swift-builder · tdd-guide<br/>swift-build-resolver"]
        E2["reviewers<br/>code-critic · swift-reviewer<br/>silent-failure-hunter<br/>security-auditor · ai-reviewer<br/>database-reviewer · a11y-architect"]
        E3["design + QA<br/>ui-designer · qa-tester"]
    end

    subgraph WEB ["🌐 Web team → the marketing site"]
        direction LR
        W1["web-copywriter"]
        W2["web-builder"]
        W3["web-claims-auditor"]
    end

    SHARED["🔁 Shared: planner · code-simplifier · docs-keeper<br/>brief must say which team"]
    ENG -.-> SHARED
    WEB -.-> SHARED

    ENG ==>|writes| SRC[("Sources/ · Tests/ · docs/")]
    WEB ==>|writes| SITE[("website/ only")]
    WEB -.->|may READ, never write| SRC

    style F fill:#0A84FF,stroke:#0A84FF,color:#fff
    style TL fill:#1c1c1e,stroke:#0A84FF,color:#fff
    style SITE fill:#5E5CE6,stroke:#5E5CE6,color:#fff
```

The boundary is enforced, not just promised: web sessions run gstack
`/freeze website/`, which physically restricts edits to that folder.

---

## 6. Founder gates — where work stops and waits

```mermaid
flowchart LR
    G1["Mockup<br/>approval"] --> G2["Milestone<br/>sign-off"] --> G3["Anything that<br/>costs money"] --> G4["Anything with security<br/>implications"] --> G5["Putting the<br/>website live"]

    style G1 fill:#FFB340,stroke:#C93400,color:#000
    style G2 fill:#FFB340,stroke:#C93400,color:#000
    style G3 fill:#D70015,stroke:#D70015,color:#fff
    style G4 fill:#D70015,stroke:#D70015,color:#fff
    style G5 fill:#D70015,stroke:#D70015,color:#fff
```

Everything currently sitting at one of these gates is in
[[open-work]] › *Waiting on the founder*.

---

**Related:** [[workflow]] · [[agent-roster]] · [[open-work]] · [[architecture]] · [[00-Overview]]
