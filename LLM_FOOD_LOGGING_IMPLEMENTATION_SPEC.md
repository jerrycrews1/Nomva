# Nomva LLM Food Logging Implementation Spec

## Purpose

This document defines the target architecture for Nomva's AI-driven logging system.
The goal is to make the LLM the primary orchestrator of food logging, meal editing,
history querying, and nutrition reasoning, while keeping database writes and
nutrition calculations safe, deterministic, and auditable.

This spec replaces the current "single prompt + fuzzy USDA lookup + immediate save"
pattern with an agentic tool-using workflow.


## Product Goal

Nomva should behave like a reliable nutrition copilot:

- The user speaks naturally.
- The LLM determines intent.
- The LLM decides whether it has enough information to act.
- The LLM can inspect local data, search food sources, ask one high-value
  clarifying question, and then complete the task.
- The app only commits side effects when the chosen food resolution is grounded
  in retrieved evidence or user confirmation.

The user should feel like they are talking to an intelligent assistant, not
filling out forms or debugging a search engine.


## Core Product Principles

1. The LLM should do as much reasoning as possible.
2. The app should expose tools and validation, not hardcoded business guesses.
3. The food database is evidence, not authority.
4. Ambiguous inputs should trigger clarification, not silent logging.
5. Personal data should outrank generic public database matches whenever possible.
6. Provider differences should not radically change behavior.
7. All logged entries should be explainable: what food was chosen, why, and from where.


## Current Problems

### 1. Retrieval quality is too poor for autonomous logging

The current search layer is FTS5 over only `name` and `brand`. That causes broad
term collisions such as:

- `milk` returning `milk chocolate`, `milkshake`, and candy-like results
- `cheese` returning processed or compound items such as `Cheesefurter`
- `egg` returning `egg salad`, `eggnog`, and candy-like matches

Because the candidate set is noisy, the LLM is often asked to "pick the best
fdc_id" from bad options.

### 2. The reranker is not safe enough

The current reranker uses a handcrafted penalty list that accidentally penalizes
real foods such as `cheese` itself. That makes correct results less likely for
generic foods.

### 3. The system logs too early

The current pipeline often turns the top lexical match into a `FoodEntry`
immediately, even when:

- the food identity is vague
- the portion is vague
- there are multiple equally plausible candidates
- the user likely omitted calorie-changing add-ins

### 4. Conversation state is implicit instead of structured

Clarification handling currently depends on chat text and short recent-message
windows instead of explicit unresolved slots. This makes follow-up answers brittle.

### 5. Personal knowledge is not integrated into food resolution

The app stores:

- `CustomFood`
- `MealTemplate`
- `FoodEntry` history
- `ChatMessage` history

but the AI logging pipeline still behaves like it only has USDA search.

### 6. Provider behavior is inconsistent

The provider abstraction exists, but the app currently uses Apple Foundation
Models only. If the full prompt fails, a much simpler fallback instruction set
is used, which can materially change quality.

### 7. Food data shape is too shallow

The food database does not currently store enough semantic structure for reliable
selection:

- no aliases
- no food categories
- no ingredient/prepared-food distinction
- no density data
- no unit normalization table
- no candidate confidence features


## Scope

### In Scope

- Food logging
- Multi-item meal logging
- Clarification questions
- Editing, replacing, and deleting food logs
- Goal and weight operations through the same agent loop
- Local history lookup
- Custom food integration
- Meal template integration
- Safer food retrieval and ranking
- Better provider isolation

### Out of Scope for Phase 1

- Photo-based food recognition
- Restaurant menu APIs
- Online nutrition APIs beyond local USDA data
- Autonomous health coaching recommendations
- Medical decision support


## High-Level Architecture

### Target Flow

1. User sends a natural-language message.
2. The app creates or resumes a structured `AgentTaskState`.
3. The LLM receives:
   - system instructions
   - current task state
   - recent relevant conversation
   - available tools
4. The LLM chooses one of:
   - ask clarification
   - search foods
   - inspect history
   - inspect custom foods
   - inspect templates
   - commit log/edit/delete action
   - reply without side effects
5. The app executes the requested tool call.
6. Tool results are fed back to the LLM.
7. The loop continues until:
   - the LLM returns a final grounded action
   - the LLM asks a clarification question
   - the app blocks the action due to safety/ambiguity rules
8. The app validates and commits the final mutation.
9. The user sees a natural-language confirmation with the resolved foods.

### Design Rule

The LLM is responsible for reasoning and orchestration.
The app is responsible for:

- data access
- schema validation
- candidate generation
- safe mutation boundaries
- nutrition calculation
- deterministic fallback behavior


## Required New Concepts

### 1. Agent Task State

Add a structured task state model that exists independently of chat text.

```swift
struct AgentTaskState: Codable {
    var taskId: UUID
    var status: TaskStatus
    var intent: AgentIntent?
    var messageDate: Date
    var mealContext: MealContext?
    var pendingItems: [PendingFoodItem]
    var unresolvedSlots: [UnresolvedSlot]
    var candidateGroups: [CandidateGroup]
    var lastQuestion: ClarificationQuestion?
    var referencedEntryIDs: [UUID]
}
```

#### Supporting types

- `TaskStatus`: `collecting`, `awaiting_clarification`, `ready_to_commit`, `completed`
- `AgentIntent`: `log_food`, `edit_entry`, `replace_entry`, `delete_entry`, `delete_meal`, `query`, `log_weight`, `set_goal`
- `MealContext`: date, inferred meal, time phrase, confidence
- `PendingFoodItem`: one logical food the user is trying to log
- `UnresolvedSlot`: `identity`, `portion`, `add_ins`, `preparation`, `brand`, `fat_percent`, `milk_type`, etc.
- `CandidateGroup`: candidate foods generated for one pending item
- `ClarificationQuestion`: exact question, target slots, item reference

This state should be persisted in SwiftData or kept in-memory per day/session.
SwiftData persistence is preferred so clarification survives app backgrounding.


## Data Model Changes

### New SwiftData Models

#### `LoggingSession`

Tracks the active AI task for the current conversation thread.

Fields:

- `id`
- `createdAt`
- `updatedAt`
- `status`
- `serializedState`
- `dayDate`

#### `ResolvedFoodEvidence`

Attaches evidence to each logged `FoodEntry`.

Fields:

- `id`
- `foodEntryID`
- `sourceType` (`usda_branded`, `usda_sr_legacy`, `custom_food`, `meal_template`)
- `fdcId`
- `matchedName`
- `matchedBrand`
- `searchTerms`
- `candidateSummary`
- `resolutionConfidence`
- `wasClarified`

This gives us auditability and future debugging support.


## Food Database Changes

### Existing Table Problems

The current `foods` table stores:

- `name`
- `brand`
- `source`
- `serving_g`
- `serving_desc`
- macros
- barcode

That is not enough for robust food reasoning.

### Required Schema Extensions

Add these fields to the generated SQLite database:

- `canonical_name`
- `normalized_name`
- `alias_blob` or `aliases_json`
- `category`
- `subcategory`
- `is_branded`
- `is_generic`
- `is_single_ingredient`
- `is_prepared_food`
- `is_beverage`
- `is_candidate_for_quick_log`
- `household_serving_kind`
- `default_unit`
- `default_unit_amount`
- `density_g_per_ml` when applicable

### Additional Search Structures

Add:

- `foods_alias_fts`
- `foods_search_tokens`
- optional `foods_embedding` table for future semantic ranking

Phase 1 can skip embeddings if needed, but category features are mandatory.

### Importer Changes

Update `scripts/build_db.py` so the build pipeline also:

- normalizes USDA names
- derives a canonical name
- classifies the food category using deterministic rules
- marks branded vs generic
- extracts alias candidates from common USDA phrasing
- flags low-quality search rows that should not rank highly for generic terms

Example:

- `Cheesefurter, Cheese Smokie, Pork, Beef`
  - category: `processed_meat`
  - subcategory: `sausage`
  - `is_single_ingredient = false`
  - `is_candidate_for_quick_log = false`

- `Cheese, Cheddar, Sharp, Sliced`
  - category: `dairy`
  - subcategory: `cheese`
  - `is_single_ingredient = true`
  - `is_candidate_for_quick_log = true`


## Tool Surface

The LLM should no longer infer food choices from a single static candidate list.
Instead, it should use explicit tools.

### Tool: `search_foods`

Input:

```json
{
  "query": "cheese",
  "context": {
    "meal": "lunch",
    "user_phrase": "two slices of cheese"
  },
  "filters": {
    "prefer_generic": true,
    "prefer_single_ingredient": true,
    "category": "dairy"
  }
}
```

Output:

- top candidates
- feature summaries
- reasons the search layer thinks they match
- confidence bands

### Tool: `lookup_food_by_id`

Fetches full details for one candidate.

### Tool: `search_custom_foods`

Searches `CustomFood` first when the user names a familiar or repeated item.

### Tool: `search_recent_foods`

Searches recent `FoodEntry` history to find:

- foods the user logs often
- user-specific naming habits
- likely repeat meals

### Tool: `search_meal_templates`

Allows the LLM to match phrases like:

- `my usual breakfast`
- `the smoothie I always have`

### Tool: `get_recent_log`

Provides relevant food history in structured form, not prose.

### Tool: `get_weight_history`

Structured weight data for trend questions.

### Tool: `get_goals`

Structured current macro targets.

### Tool: `commit_log_food`

Takes a fully resolved payload:

```json
{
  "items": [
    {
      "source": "usda",
      "fdc_id": 170899,
      "portion_grams": 56,
      "portion_description": "2 slices",
      "meal": "lunch",
      "raw_user_input": "For lunch I had two slices of cheese",
      "evidence": {
        "reason": "Best generic sliced cheese candidate after clarification-free high-confidence match",
        "confidence": 0.86
      }
    }
  ]
}
```

The app validates this before inserting `FoodEntry`.

### Tool: `commit_edit_entry`

### Tool: `commit_delete_entry`

### Tool: `commit_replace_entry`

### Tool: `commit_set_goal`

### Tool: `commit_log_weight`

The LLM should never mutate storage directly. All mutations go through tool calls.


## Agent Loop

### Loop Rules

Max tool iterations per user turn: 6

Stop conditions:

- final committed action
- clarification asked
- unsupported request
- ambiguity not reducible with one concise question

### Target Loop

```text
User message
-> infer intent
-> decide if more evidence is needed
-> call tools
-> inspect candidates/history
-> ask clarification OR commit action
```

### Required LLM Behaviors

The LLM must:

- decompose multi-item meals
- identify missing calorie-driving information
- prefer user history over generic branded foods
- explicitly compare candidates when ambiguity exists
- avoid logging low-confidence matches
- ask at most one short question per turn unless the user is in a repair flow


## Clarification Policy

### Ask a clarification when any of these are true

- food identity is generic and multiple categories fit
- portion is too vague and materially affects calories
- add-ins or preparation method likely change calories by more than 15%
- multiple candidates remain plausible after retrieval
- the top candidate is branded or processed but the user described a generic food

### Do not ask when

- the food is highly specific and high-confidence
- the user gave a clear serving and clear preparation
- history strongly indicates the same exact item and there is low ambiguity

### Clarification Examples

Input:

- `For lunch I had two slices of cheese`

Correct question:

- `What kind of cheese was it, and were those sandwich slices or cut slices from a block?`

Input:

- `I had a coffee`

Correct question:

- `Was that black coffee, or did it have milk, cream, sugar, or flavoring?`

Input:

- `I had Chipotle`

Correct question:

- `What did you get at Chipotle?`

### Slot-Based Clarification

Clarification should fill explicit unresolved slots, for example:

- `identity.kind_of_cheese`
- `portion.slice_size`
- `add_ins.milk`
- `preparation.fried_vs_scrambled`

This is the key change from today's fragile text-only follow-up handling.


## Retrieval and Ranking Spec

### Candidate Generation

Candidate generation should combine four sources in this order:

1. recent personal food history
2. custom foods
3. meal templates
4. USDA database

The LLM may still choose a lower-ranked source, but the app should expose all
candidate metadata clearly.

### Ranking Features

Rank candidates using weighted features:

- exact normalized phrase match
- canonical-name match
- alias match
- category compatibility
- single-ingredient preference for generic user phrasing
- portion compatibility
- branded penalty for generic requests
- processed-food penalty when user asked for a plain ingredient
- user history boost
- custom-food boost
- recent-log boost
- calorie plausibility for stated portion

### Hard Exclusions

For certain queries, veto cross-category contaminants:

- `milk` should strongly demote `milk chocolate`, `milkshake`, and candy unless
  words like `chocolate`, `shake`, `candy`, or `dessert` are present.
- `cheese` should strongly demote sausages, burgers, pasta dishes, popcorn, and
  snacks unless the user indicated a prepared food.
- `egg` should strongly demote `eggnog`, `egg salad`, candy, and prepared dishes
  unless requested.

### Candidate Confidence

Each candidate must return:

- `retrieval_score`
- `fit_score`
- `explanation`
- `requires_clarification`

The app should never auto-log a candidate below a defined confidence threshold.

### Thresholds

- `>= 0.85`: auto-log allowed
- `0.55 - 0.84`: clarification or comparison required
- `< 0.55`: ask for a better description


## Portion Resolution Spec

### Target Behavior

The LLM should infer portion structure, but the app should validate and normalize it.

Examples:

- `2 slices`
- `1 cup`
- `small bowl`
- `half a burrito`
- `normal serving`

### Portion Resolver Responsibilities

Add a deterministic `PortionResolver` layer that:

- converts servings into grams when serving data exists
- uses category defaults when household measures are vague
- returns a confidence score
- flags unresolved portion ambiguity

### Rules

- If the user gives a USDA-compatible serving, use it directly.
- If the user gives a household measure and density exists, convert.
- If the user gives vague language like `normal serving`, use a category default
  only if that category is stable and low-risk.
- If portion ambiguity can swing calories materially, ask.


## Personalized Resolution Spec

### Recent Foods

The system should learn from prior logs:

- if the user logs the same cheese brand often, it should rank above generic USDA
- if the user repeatedly logs one exact milk, that should influence future `2% milk` matches

### Custom Foods

Custom foods must be first-class candidates in the agent loop.

If the user says:

- `my protein shake`
- `the turkey sandwich I usually have`

the model should be able to inspect custom foods and recent foods before USDA.

### Meal Templates

Meal templates should support:

- saving common combinations
- reusing repeated meals
- expanding a single user phrase into multiple food entries


## Provider Layer Spec

### Requirements

All providers must support the same agent contract:

- structured system instructions
- tool call round-trips
- stable JSON output
- conversation state payloads

### Apple Foundation Models

Keep as the default provider, but:

- do not silently drop to a much weaker prompt without surfacing reduced capability
- track whether fallback mode was used
- expose diagnostics internally for QA builds

### Local Model Provider

Re-enable local provider support only when:

- the model can follow JSON/tool instructions reliably
- the app has a stable local runtime path
- the feature is honestly represented in Settings

Until then, remove or rewrite misleading UI copy.


## UX Spec

### Chat Responses

User-visible responses must never show:

- raw JSON
- fenced code
- candidate internals
- debugging traces

### Confirmation Tone

Good confirmation:

- `Logged cheddar cheese (2 slices) — 228 cal`

Good clarification:

- `What kind of cheese was it?`

Bad confirmation:

- `Logged: Cheesefurter, Cheese Smokie, Pork, Beef (2 slices) — 656 cal`

### Failure Behavior

If confidence is low:

- ask for clarification

If no useful candidates exist:

- ask for a better description
- optionally suggest creating a custom food


## Acceptance Tests

### High Priority Food Cases

#### Generic ingredient cases

- `For lunch I had two slices of cheese`
  - must not log `Cheesefurter`
  - must ask what kind of cheese unless strong personal history exists

- `I had eggs`
  - must not log `eggnog` or `egg salad`

- `I had milk`
  - must not log `milk chocolate`

#### Clarification carry-forward

- `For breakfast I had Frosted Flakes`
- assistant asks about milk and amount
- user: `A normal bowl with 2% milk`
  - must resolve against cereal + milk
  - must not drift to oatmeal

#### Personalization

- if user logs `Fairlife 2% milk` repeatedly, later `2% milk` should prefer that

#### Multi-item meals

- `Two eggs, bacon, and toast`
  - must create three pending items
  - must resolve each separately

#### Edit flow

- `Actually make that one slice`
  - must edit the last relevant entry, not create a new one

### Query Cases

- `How many calories did I have yesterday?`
- `What did I eat most this week?`
- `Delete lunch`
- `Change my calorie goal to 2100`

### Provider Reliability Cases

- full prompt path succeeds
- fallback path detected and flagged
- JSON parse failure results in graceful recovery


## Metrics

Track these internally:

- auto-log accuracy
- clarification rate
- correction rate within 5 minutes of logging
- replacement rate
- not-found rate
- cross-category mismatch rate
- provider fallback rate
- average tool loops per successful log

Primary success metric:

- percentage of food logs accepted by the user without immediate correction


## Implementation Plan

### Phase 1: Stabilize retrieval and logging safety

- fix reranker bugs
- add category-aware search filters
- add confidence thresholds
- stop auto-logging low-confidence generic foods
- remove misleading provider UI copy

### Phase 2: Add structured agent state

- introduce `LoggingSession`
- add unresolved slot tracking
- support explicit clarification actions
- merge clarification answers into structured state

### Phase 3: Expand tool surface

- add recent-food search
- add custom-food search
- add meal-template search
- move history queries to structured tools

### Phase 4: Upgrade the food database

- extend importer schema
- add category and alias generation
- improve household measure support
- add richer ranking features

### Phase 5: Provider parity and evaluation

- normalize provider behavior
- re-enable local model path only if stable
- add regression suite for known bad examples


## Immediate Engineering Tasks

1. Remove `cheese` from reranker noise penalties and rework category vetos.
2. Add a first-class `ask_clarification` response/action shape.
3. Add confidence gating before `resolveAndLog` commits any food.
4. Add custom-food and recent-food candidate retrieval before USDA search.
5. Replace prose-style candidate injection with structured tool results.
6. Add structured `LoggingSession` state for follow-up turns.
7. Rewrite Settings copy so it matches actual provider support.
8. Add a regression test suite for `cheese`, `milk`, `egg`, cereal + milk, and edit flows.


## Definition of Done

The new system is considered successful when all of the following are true:

- generic food inputs no longer auto-log absurd cross-category matches
- follow-up answers reliably fill the intended prior food item
- custom foods and history influence ranking
- the LLM can use multiple tools before committing
- confidence gating prevents low-quality autonomous logging
- UI copy accurately reflects provider capabilities
- regression cases pass consistently on-device

