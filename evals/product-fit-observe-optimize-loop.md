# Observe → Optimize: Fixing the Product Fit Overclaim

## A worked example of eval-driven agent improvement

**Scope of this document:** one specific, fully-closed-loop finding — the Product Fit
section confidently overselling a generic product match to an account with no
real industry fit. This is used here as the reference example for how the
evaluation layer (deterministic + native platform + LLM-judge) was used to
*find* a real behavioral bug, *diagnose* its root cause, *fix* it with a
targeted instruction change, and *verify* the fix — the Observe → Optimize
loop, end to end, with evidence at each step.

---

## TL;DR

| | Before | After |
|---|---|---|
| Product Fit language | *"...are a **strong fit** for consulting firms..."* | *"There is **no industry-validated product fit** for consulting, but... **may be worth exploring**..."* |
| Native Response Test (Testing Center) | ❌ Fail | Not yet re-run in batch (see Status) |
| Custom deterministic check | ❌ Fail (Case A only — see the blind-spot finding below) | ✅ Pass (but see caveat) |
| LLM-judge verdict | ❌ **FAIL, severity 4/5** (confirmed) | ⏳ Predicted PASS — **not yet run, see Status** |

---

## The Observe → Optimize Loop

**OBSERVE** → **DIAGNOSE** → **OPTIMIZE** → **VERIFY** → *(if it doesn't hold, loop back to OBSERVE)*

| Step | What happens |
|---|---|
| **1. OBSERVE** | Run evals, find a real failure |
| **2. DIAGNOSE** | Find the root cause, not just the symptom |
| **3. OPTIMIZE** | Change the instruction that actually drives the behavior |
| **4. VERIFY** | Re-run the same evals; confirm the fix holds — if it doesn't, go back to step 1 |

---

## Step 1 — OBSERVE: the baseline eval run found it

Ten deterministic test cases were run through Salesforce's native **Testing
Center**, covering regression tests for known bugs plus the verified account
table. One case — **DET-04, "Research Dickenson plc for me"** (Consulting,
an industry with no genuine case-study or product-vertical match) — came back
with a native evaluation result of:

| Metric | Result |
|---|---|
| Subagent Test Result | Pass |
| Action Test Result | Pass |
| **Response Test Result** | **Fail** |
| Instruction Adherence | High |
| Completeness | Fail |
| Coherence | Pass |

The actual response text that triggered the Response Test failure:

> *"Standby and Emergency Generator Systems are a strong fit for consulting
> firms that require reliable backup power to avoid operational or financial
> disruption. The offering includes right-sizing assessments, diesel or
> natural gas options, and a 4–8 week deployment timeline from site
> assessment to activation."*

**What's notable here:** the same response's Case Study section behaved
correctly — *"No relevant case study proof point available for the consulting
industry"* — proving the agent is capable of honest "no match" framing. It
just wasn't being held to that same standard in the Product Fit section. That
contrast is what turned this from "huh, interesting" into a real, actionable
finding: one section already does the right thing, so the fix is about
extending an existing pattern, not inventing a new one.

**A custom deterministic check confirmed the same failure independently:**

```python
generic_fit_overclaim_check(response_text, "Consulting")
# → passed=False
# → detail: "overclaiming strong/perfect fit language in an industry
#    with only the 'All Industries' generic tag"
```

Two independent eval layers — one native/LLM-graded, one a hand-written
keyword check — agreed. That agreement is what made this worth fixing rather
than dismissing as a one-off.

---

## Step 2 — DIAGNOSE: root cause, and an eval blind spot along the way

**Root cause:** `Case_Studies_DMO` has exactly 4 documents, strictly tagged
one per industry (Electronics/Networking, Biotechnology,
Manufacturing/Logistics, Hospitality) — so when the retriever searches for
Consulting, it correctly returns nothing, and the model reports that
honestly. `Product_OnePagers_DMO`, by contrast, has only 2 documents tagged
broadly ("All Industries" plus specific verticals) — so the retriever
*always* returns something, even for an industry with no genuine fit,
because the generic tag technically matches every query. The model then
treated "a document matched" as equivalent to "this is a validated fit,"
which it wasn't.

**A second, real test — same account, different wording — surfaced a
deeper problem with the eval tooling itself, not just the agent.** A second
live run against the same unmodified agent produced a different response
with no trigger phrase at all:

> *"The Standby and Emergency Generator Systems offering fits consulting
> clients advising on resiliency and continuity, providing right-sizing
> assessments, fuel option guidance, and 4–8 week deployment timelines that
> support projects with tight uptime requirements."*

Running the same custom check against this text:

```python
generic_fit_overclaim_check(response_text_2, "Consulting")
# → passed=True   ← FALSE NEGATIVE
# → detail: "no overclaim in a generic-fit context"
```

**This is the same overclaim, wearing different words — and the keyword
check missed it entirely**, because it only looks for a fixed phrase list
(`"strong fit"`, `"perfect fit"`, etc.). This was an important intermediate
finding: **a single deterministic layer isn't sufficient for this failure
class.** It's why an LLM-judge layer was built as a second check, purpose-built
to judge *effect on the reader* rather than match specific words — see
`llm_judge_product_fit_overclaim.md` for the full prompt design, built and
validated specifically against these two real response variants.

---

## Step 3 — OPTIMIZE: the actual fix

The fix targets `Outreach_Agent`'s reasoning instructions — the subagent
responsible for synthesizing the final Product Fit section — since that's
where the confident wording is generated, not the retriever or the Apex
layer underneath it.

**Before:**
```
|**Product Fit**
|- The relevant product specification match, if any was found
```

**After:**
```
|**Product Fit**
|- The relevant product specification match, if any was found
|- Only use confident, specific language (e.g. "strong fit," or product
|  detail framed as tailored to this account's situation) if the account's
|  industry is one of the verified verticals: Electronics, Networking,
|  Biotechnology, Manufacturing, Logistics, or Hospitality.
|- For any other industry, the match came from a generic "All Industries"
|  tag, not a vetted industry fit. Present it as exploratory rather than
|  confidently endorsed (for example, "may be worth exploring" or "could
|  apply if..."), and do not frame generic product detail — assessments,
|  timelines, SLA specifics — as if it had been validated for this
|  specific industry.
```

And the closing "no fabrication" instruction was strengthened to explicitly
name this failure mode instead of leaving it implicit:

**Before:**
```
|If any section has no information available, state that plainly rather
|than inventing content.
```

**After:**
```
|If any section has no information available, state that plainly rather
|than inventing content. This includes never presenting a generic,
|all-industries product match as if it were an industry-specific fit.
```

This mirrors the exact instructional pattern the Case Study section already
follows successfully — extending a working pattern to a section that wasn't
yet held to it, rather than introducing new logic.

---

## Step 4 — VERIFY: re-running the same account after the fix

Same utterance, same account, new agent version with the instruction change
applied:

> *"There is no industry-validated product fit for consulting, but offerings
> such as Standby and Emergency Generator Systems, as well as Installation
> and SLA Maintenance Programs, may be worth exploring if Dickenson plc
> advises clients with facilities where operational downtime poses a risk.
> These solutions provide generator options, rapid deployment, and ongoing
> support, but applicability would depend on the specific needs of their
> client base."*

Read against the instruction: it now opens with an explicit disclaimer ("no
industry-validated product fit"), frames everything else conditionally
("may be worth exploring," "would depend on"), and never asserts a
deployment detail as validated for this account. This is a genuine behavior
change, not a coincidence of phrasing.

**Re-running the same custom deterministic check:**
```python
generic_fit_overclaim_check(after_fix_text, "Consulting")
# → passed=True
# → detail: "no overclaim in a generic-fit context"
```

**Important honesty check on this result:** this Pass does **not**, by
itself, prove the fix worked — the same check also passed the
*pre-fix, non-triggered-phrase* response in Step 2. A keyword-absence check
cannot distinguish "this is now honestly hedged" from "this happens not to
contain my keyword list" — that's the exact blind spot already identified.
**The deterministic check is necessary but not sufficient evidence here.**

**This is precisely why the LLM-judge layer exists**, and it's the piece
that actually validates a behavior change rather than a wording coincidence:
a purpose-built judge prompt (`llm_judge_product_fit_overclaim.md`) was
built and run against the two *pre-fix* variants side by side:

| Case | Response | Judge Verdict (confirmed, real run) |
|---|---|---|
| A | "...are a **strong fit**..." (trigger phrase) | **FAIL, severity 4/5** — *"Without a verified vertical match, asserting this is 'a strong fit'... presents generic product details as if tailored to this industry."* |
| B | "...fits consulting clients advising on..." (no trigger phrase) | **FAIL, severity 4/5** — *"No overclaim keyword present, but the text still asserts industry-specific rationale... same overclaim, softer wording."* |

Both pre-fix variants correctly failed — confirming the judge generalizes
across phrasing where the keyword check couldn't, exactly the property it
was designed for.

---

## Status: what's confirmed vs. what's still open

✅ **Confirmed, with real evidence:**
- Native Testing Center caught the original overclaim (Response Test: Fail)
- Custom deterministic check caught the original overclaim (Case A)
- The same custom check missed a rephrased version of the identical overclaim (Case B) — a real, demonstrated blind spot
- The instruction fix produces a genuinely different, properly hedged response on live re-test
- The LLM-judge correctly failed both pre-fix variants (A and B), independently confirming the deterministic check's blind spot from a different angle
