---
name: spec-linear
description: Spec out Linear projects/issues through collaborative Q&A
disable-model-invocation: true
user-invocable: true
metadata:
  internal: true
---

# Linear Spec Generator

Collaboratively spec out Linear projects or issues through a structured question-and-answer flow with draft review before syncing.

## Input: `$ARGUMENTS`

The `$ARGUMENTS` parameter contains unstructured instructions describing what needs to be built or fixed.
This can be anything from a quick bug description to detailed feature requirements.

## Instructions

### Step 1: Establish the Target Team

Linear organizes work under teams, and every project and issue must belong to one.
Before drafting, determine which team this spec targets.

1. **If the user named a team**, use that.
2. **Otherwise, discover the available teams** with `mcp__linear__list_teams` and either infer the correct one from context or ask the user which team to use.
3. Remember the resolved team and its issue-key prefix (for example `ABC` in `ABC-123`) for the rest of the flow.

### Step 2: Check for Existing Duplicates

Before any analysis or drafting, check Linear for potential duplicates:

1. **Extract key terms** from `$ARGUMENTS` - identify the system or app area, the feature area, and the core problem or feature being described.

2. **Search for similar issues** using `mcp__linear__list_issues` (scoped to the target team) with a query built from the key terms.
Try a few variations if the first search is too narrow.

3. **If the input describes a project**, also search for similar projects using `mcp__linear__list_projects` with a relevant query.

4. **If potential duplicates are found**, present them to the user:

```
## Potential Duplicates Found

I found existing items that might already cover this:

- **[Issue/Project Title]** ([ISSUE-KEY](url)) - [brief description of what it covers]

Would you like to:
1. **Update the existing item** - I'll help you discuss and apply changes to it
2. **Create a new item anyway** - proceed with the normal spec flow
3. **Cancel** - stop so you can review the existing items first
```

**Wait for the user's choice before continuing.**
If the user chooses to update an existing item, shift into a collaborative discussion about what changes to make.
If they choose to create new, proceed to Step 3.

5. **If no duplicates are found**, proceed silently to Step 3.

### Step 3: Analyze Input and Determine Type

Read the `$ARGUMENTS` to understand:

1. **Spec Type**: Is this a **Project** (collection of related issues) or a **standalone Issue**?
   - Project: Multiple related pieces of work, a feature set, or an initiative
   - Issue: A single bug fix, feature, or improvement

2. **Issue Type(s)**: For each issue identified, determine if it's a:
   - **Bug**: Something broken that needs fixing
   - **Feature**: New functionality to be added
   - **Improvement**: Enhancement to existing functionality

3. **Provided vs Missing Information**: Note what the user has already specified vs what needs to be asked.

### Step 4: Ask Clarifying Questions

**ALWAYS ask clarifying questions before drafting.**
Group your questions into:

#### Required Information (ask if not provided):

**For Projects:**
- Project name and description
- Priority (Urgent, High, Medium, Low, No Priority)
- Status - Linear's built-in project states are Backlog, Planned, In Progress, Completed, and Canceled; suggest **Planned** as the default
- Confirm the current user should be the project lead (default: yes)

**For Issues:**
- Priority (Urgent, High, Medium, Low, No Priority)
- Status - suggest the team's default starting workflow state; discover the team's states with `mcp__linear__list_issue_statuses` if you need the exact names, and ask if a different status is needed
- Assignee - mention default is **Unassigned**, ask if someone should be assigned
- Project to add to - mention default is **None**, ask if it belongs to an existing project

#### Clarifying Questions About Requirements:

Ask about anything ambiguous in the requirements:
- Edge cases
- User flows
- Scope boundaries
- Any assumptions you're making

**Important**: Keep questions concise and grouped logically.
Don't overwhelm with too many questions at once.

### Step 5: Organizational Approach (if 3+ issues)

**If the spec will result in 3 or more issues**, present a high-level organizational summary BEFORE drafting full details:

```
## Proposed Issue Organization

I'm planning to create the following issues:

1. **[App]: [Feature Area] - [Title]** (Bug/Feature/Improvement) - one-line summary
2. **[App]: [Feature Area] - [Title]** (Bug/Feature/Improvement) - one-line summary
3. **[App]: [Feature Area] - [Title]** (Bug/Feature/Improvement) - one-line summary
...

Does this breakdown make sense, or would you like to reorganize?
```

Wait for user confirmation before proceeding to the draft.

### Step 6: Draft the Spec

Create a formatted draft for review.
Use the appropriate template based on issue type:

---

#### Project Draft Template

```
# PROJECT: [Project Name]

**Description:** [Brief project description]
**Status:** [Planned/Backlog/In Progress/Completed]
**Priority:** [Urgent/High/Medium/Low/No Priority]
**Lead:** [Current user - will be set automatically]
**Team:** [Target team]

---

## Issues

### Issue 1: [App]: [Feature Area] - [Title]
**Type:** [Bug/Feature/Improvement]
**Priority:** [Priority]
**Status:** [Default workflow state]
**Assignee:** Unassigned

[Issue content per template below]

---

### Issue 2: [App]: [Feature Area] - [Title]
...
```

---

#### Feature/Improvement Issue Template

```
### [App]: [Feature Area] - [Issue Title]
**Type:** Feature/Improvement
**Priority:** [Priority]
**Status:** [Default workflow state]
**Assignee:** Unassigned

#### Description
[1-3 sentences providing context and the high-level goal]

#### Functional Requirements
[Mix of prose and bullet points describing what should happen]

- Requirement 1
- Requirement 2
- Requirement 3

#### UI Copy (if applicable)
[Include this section when the feature has user-facing text. Provide exact copy for labels, tooltips, error messages, empty states, confirmation dialogs, etc.]

| Element | Copy |
|---------|------|
| Field Label | "Amount (CAD)" |
| Tooltip | "This value will appear in downstream reports. Please enter the amount in the correct currency." |
| Error State | "A value is required because this record uses a different currency than the default." |
```

**Example titles:**
- `Billing: Invoices - Add currency conversion tooltip`
- `Admin: Permissions - Allow bulk role assignment`
- `Hiring: Candidates - Export interview feedback to PDF`

---

#### Bug Issue Template

```
### [App]: [Feature Area] - [Issue Title]
**Type:** Bug
**Priority:** [Priority]
**Status:** [Default workflow state]
**Assignee:** Unassigned

#### Description
[1-2 sentences describing the bug]

#### Steps to Reproduce
1. Step 1
2. Step 2
3. Step 3

#### Expected Behavior
[What should happen]

#### Actual Behavior
[What currently happens]
```

**Example titles:**
- `Scheduling: Planner - Optional skills filter incorrectly excludes people`
- `Admin: Users - Profile photo upload fails silently`
- `Vault: Inbox - File preview not loading for PDFs`

---

### Step 7: Review Checkpoint

**ALWAYS** present the draft and ask:

```
## Draft Review

Please review the draft above. Let me know if you'd like to:
- Add, remove, or modify any issues
- Change priorities, assignees, or other fields
- Adjust any descriptions or requirements
- Proceed to sync to Linear

I won't create anything in Linear until you confirm.
```

**Wait for explicit confirmation** before proceeding.

### Step 8: Final Duplicate Re-check

Re-run the same searches from Step 2 to catch any items that may have been created by someone else during the drafting process.
**Only alert the user about NEW matches** - ignore any duplicates that were already surfaced and acknowledged in Step 2.

1. Search for similar issues using `mcp__linear__list_issues` with the same key terms from Step 2.
2. If the spec includes a project, also search for similar projects using `mcp__linear__list_projects`.
3. Compare results against what was found in Step 2 - only flag items that are **new** since then.

**If new matches are found**, alert the user:

```
## New Potential Duplicates Found

Since we started drafting, these new items appeared in Linear:

- **[Issue/Project Title]** ([ISSUE-KEY](url)) - [brief description]

Would you like to:
1. Proceed with creating new items anyway
2. Update the existing items instead (I'll show you what would change first)
3. Cancel and review the existing items first
```

**If no new matches are found**, proceed silently to the next step.

**Never update existing specs without explicit user confirmation.**

### Step 9: Sync to Linear

Once the user confirms, use Linear MCP tools to create the items:

**For Projects:**
1. Use `mcp__linear__save_project` with:
   - `name`: Project name
   - `description`: Project description
   - `team`: The target team
   - `state`: The confirmed status
   - `priority`: The confirmed priority (as number: 0=No Priority, 1=Urgent, 2=High, 3=Medium, 4=Low)

2. For each issue in the project, use `mcp__linear__save_issue` with:
   - `title`: Issue title
   - `description`: Full issue content (formatted as markdown)
   - `team`: The target team
   - `project`: The created project's ID
   - `priority`: Priority number
   - `labels`: Appropriate label (Bug, Feature, or Improvement)

**For Standalone Issues:**
Use `mcp__linear__save_issue` with the appropriate fields.

### Step 10: Summary

After syncing, provide a summary:

```
## Synced to Linear

### Project Created
- **[Project Name](Linear URL)** - Status: [Status], Priority: [Priority]

### Issues Created
| Issue | Type | Priority | Status | Link |
|-------|------|----------|--------|------|
| [Title] | Feature | High | [Default workflow state] | [ISSUE-KEY](url) |
| [Title] | Bug | Urgent | [Default workflow state] | [ISSUE-KEY](url) |

All items have been created in the **[Target team]** team.
```

---

## Key Principles

1. **Product-level specs**: Keep issues brief, succinct, and high-level.
NO implementation details unless the user explicitly provides them.

2. **Always review before sync**: Never create anything in Linear without showing a draft first.

3. **Don't modify existing items**: Alert the user if similar items exist and get explicit confirmation before any updates.

4. **Minimize questions**: Group questions logically and only ask what's necessary.

5. **Default values**:
   - Project Status: Planned
   - Project Lead: Current user
   - Issue Status: The team's default starting workflow state
   - Issue Assignee: Unassigned
   - Issue Project: None (unless specified)
   - Team: The team resolved in Step 1

6. **Issue type labels**: Always apply the appropriate label (Bug, Feature, or Improvement) to each issue.

7. **Issue title format**: Always prefix issue titles with the app or system area for discoverability:
   - **Issues within a project**: Use `App: Feature Area - Title` format
     - Example: `Scheduling: Planner - Optional skills filter incorrectly excludes people`
   - **Standalone issues (no project)**: Use `App: Feature Area - Title` format to provide full context
     - Example: `Admin: User Management - Cannot save role changes`
   - Use the app or system-area prefixes that match the target team's own conventions; discover them from existing issues in the team if unsure.
   - The feature area should identify the specific section, page, or module within the app.

8. **Provide specific UI copy**: When a feature includes user-facing text (tooltips, labels, error messages, empty states, etc.), always provide the **exact copy** in the spec rather than general instructions like "add a tooltip explaining X."
Write out the actual text that should appear.

   **Bad example:**
   > Add a tooltip explaining that the value cannot be edited here.

   **Good example:**
   > **Tooltip:** "This value is displayed in the client's billing currency. To make changes, please edit the source record directly."

9. **Human-centric copy**: All user-facing copy should be:
   - Written in plain, friendly language (avoid technical jargon)
   - Helpful and actionable (tell users what to do, not just what's wrong)
   - Concise but complete (no unnecessary words, but enough context)
   - Empathetic in error states (acknowledge the issue, guide to resolution)

   **Bad example:**
   > "Error: Currency mismatch detected. Value required."

   **Good example:**
   > "A value is needed because this record uses a different currency than the default. Please provide the converted amount."
