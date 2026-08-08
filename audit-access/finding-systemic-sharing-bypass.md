# Finding: Systemic Sharing Bypass Across All Flows

## Severity: High — architectural, confirmed, affects the entire data layer

## Summary

Every Flow backing this agent's actions runs in **"System Context Without
Sharing — Access All Data."** This was confirmed directly on
`Find_Account_By_Name`'s Flow properties, and confirmed to be the pattern
across all Flows in the build, not an isolated setting. This means the
agent's actual data-access boundary is not determined by the running
user's permissions at all — sharing and record-level access control are
switched off entirely, by design, for every data-touching action.

## How this was found

This was discovered while trying to explain a different result: a full
SOQL audit of the running user's 5 assigned Permission Sets, plus its
Profile's own underlying permission set, found **zero object permissions**
granted on `Account`, `Lead`, `Opportunity`, or `Relationship_Signal__c` —
despite these Flows successfully reading exactly that data on every single
test run tonight. Checking the Flow's own run-mode setting directly
resolved the contradiction: the permission audit was correct and complete,
but permissions were never the actual access-control mechanism in the
first place.

## The causal chain

1. The Agent User's permission sets were never granted proper object/field
   Read access to `Account`, `Relationship_Signal__c`, or related objects
   (confirmed — see the SOQL audit results; zero matching rows across all
   5 permission sets and the Profile's hidden permission set).
2. Under normal sharing enforcement, the Flows would fail without that
   access — consistent with the stated reason for the current
   configuration ("without setting this, it was not working properly").
3. Rather than diagnosing and fixing the actual permission gap, **every
   Flow was set to bypass sharing entirely** as the path to working
   functionality.
4. **Consequence: there is currently no meaningful object- or record-level
   access boundary anywhere in this agent's data layer.** Every
   data-touching Flow can read (and, per the earlier `Contact` Edit
   finding, in at least one case write) any record of these object types
   across the entire org — not scoped to any particular account,
   relationship, or context the conversation is actually about.

## Why this matters more than a typical permission gap

This isn't "the agent has slightly more access than it needs" — it's
**"the access boundary doesn't exist as a control at all."** Two
consequences worth stating plainly:

- **It fully explains the Contact `PermissionsEdit: true` finding from
  earlier in the audit** — that finding is real, but it's actually a
  minor symptom of the same root cause, not a separate issue. The whole
  premise of that finding (checking whether the *permission set* grants
  too much) assumes permissions are the enforcement mechanism. They
  aren't — sharing is bypassed regardless of what any permission set says.
- **The AccountId verification bypass finding (see
  `finding-accountid-verification-bypass.md`) becomes more serious in this
  light, not less.** That finding showed a fabricated ID could be passed
  directly into a Flow's input, skipping verification. Combined with this
  finding: if that fabricated (or attacker-supplied real) ID had matched
  *any* real Account record anywhere in the org, "Without Sharing" means
  the Flow would have happily returned that record's data — there is no
  sharing-rule safety net underneath the missing verification step to
  catch it.

## Recommended fix (not yet implemented)

This is fixable without giving up functionality, and the pieces already
exist:

1. Add proper, least-privilege object/field Read permissions for
   `Account`, `Relationship_Signal__c`, `Account_News__c`, and any other
   objects these Flows legitimately need — to the existing custom
   permission set (`Sales_Lead_Engagement_Agent1825953114_Permissions`),
   the same one already used tonight to grant Apex Class Access for the
   citation fix.
2. Once that access is correctly granted, change each Flow's "How to Run
   the Flow" setting from "System Context Without Sharing" to **"System
   Context With Sharing"** (or "User Context," depending on whether
   record-level sharing rules beyond object permissions should also apply).
3. Re-test the full deterministic regression suite afterward — this is a
   change to the data-access layer, not the Agent Script, so it needs its
   own verification pass rather than being assumed safe because the
   conversational instructions didn't change.
4. Separately, revisit the `Contact` Edit permission found in
   `AgentforceServiceAgentSecureBase` — once sharing is properly enforced,
   confirm whether Edit access on Contact is actually needed by any
   current action (per the capability map, none currently write to
   Contact at all) and remove it if not.

## Status

✅ Confirmed directly on `Find_Account_By_Name`'s Flow properties (screenshot evidence: "System Context Without Sharing—Access All Data")
✅ Confirmed to be the pattern across all Flows in the build, not an isolated case
✅ Root cause chain fully explained: missing permissions were worked around via sharing bypass rather than fixed
⏳ `Find_Relationship_Recency`'s specific run-mode setting not yet independently re-confirmed (very likely the same, given "all flows are like this," but not yet screenshotted)
⏳ Fix identified but not yet implemented — requires both a permission set change and a Flow setting change, plus a full regression re-test afterward
