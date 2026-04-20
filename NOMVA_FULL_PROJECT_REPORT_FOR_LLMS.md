# Nomva Full Project Report for Future LLMs

Last reviewed: 2026-04-16

## 1. Purpose of This Document

This document is a full-context handoff for future LLMs, agents, or engineers
working inside the Nomva project. It is intentionally more detailed than a
typical README. The goal is to make it possible for another model to enter the
codebase and understand:

- what the product is trying to be
- what the app actually does today
- how the major systems are wired together
- where the AI logic lives
- how data moves from user input to persisted records
- what is implemented, partially implemented, or merely implied
- what quirks, contradictions, or traps exist in the current code

This report describes the current implementation, not just the intended
architecture.


## 2. One-Screen Summary

Nomva is an iOS SwiftUI app for food logging, nutrition tracking, goal
management, weight tracking, and optional iCloud sync. The app is positioned as
an "AI-first" nutrition logger where the user can type natural-language food
descriptions instead of manually searching a database.

The app is local-first:

- food data is stored in a bundled SQLite database built from USDA FoodData
  Central exports
- app data is stored in SwiftData
- the active AI backend in this build is Apple's on-device Foundation Models
  / Apple Intelligence
- no network API integration is currently implemented for logging or search

The app has four main tabs:

1. Chat
2. Log
3. Weight
4. Settings

The AI stack is more complex than it looks. It currently has three major
execution layers:

1. A focused step-by-step pipeline using narrow Foundation Models calls
2. A staged JSON food pipeline for food logging/correction
3. A legacy generic JSON agent loop

This means the app does not have one single "AI path." Different request types
may travel through different layers.


## 3. Repository Layout

Top-level directories and important files:

- `Nomva/`
  - Main iOS app source
- `Nomva.xcodeproj/`
  - Xcode project
- `scripts/`
  - Database build and deterministic evaluation scripts
- `Nomva/Resources/foods.sqlite`
  - Bundled food database used at runtime
- `LLM_FOOD_LOGGING_IMPLEMENTATION_SPEC.md`
  - Architecture/design spec for the AI logging system
- `PROJECT_UPDATE_SUMMARY.*`
  - Historical progress summaries
- `Phi-3-mini-4k-instruct-Q4_K_M.gguf`
  - Local model artifact present in repo, but not active in the build
- `sr_legacy/` and `branded/`
  - USDA JSON dataset folders used to build the food database

Important app subfolders:

- `Nomva/Models/`
  - SwiftData models and LLM response models
- `Nomva/Services/`
  - Database, goals, sync, provider abstraction, and food logging engine
- `Nomva/Views/`
  - SwiftUI screens and reusable components
- `Nomva/Scanner/`
  - Barcode scanning UI/controller
- `Nomva/Resources/`
  - Bundled SQLite food database


## 4. Product Definition

### 4.1 What Nomva is trying to be

Nomva wants to be a natural-language food logging assistant:

- the user says what they ate
- the AI figures out intent and food identity
- the app logs food, edits/deletes food, answers questions about the log,
  tracks weight, and updates goals

The onboarding language and chat empty state both reinforce this vision:

- "Just say what you ate."
- "Track what you eat by just describing it."
- "No logging. No searching. Just talk."

### 4.2 What it is today

Today Nomva is a local iOS nutrition tracker with:

- natural-language food logging in chat
- structured daily food log
- food editing/deleting
- custom foods
- barcode scan lookup from bundled USDA data
- calorie/macro goals
- weight entry logging with charting
- water tracking
- optional CloudKit-backed SwiftData persistence toggle
- a substantial but still evolving AI routing/resolution system


## 5. App Entry, Boot Sequence, and Runtime Container

### 5.1 App entry point

`NomvaApp.swift` is the app entry point.

It:

- creates a shared `SyncManager`
- injects it into the environment
- builds a SwiftData `ModelContainer`
- conditionally enables CloudKit based on `SyncManager.shared.iCloudEnabled`

### 5.2 Root view selection

`RootView` decides whether the user sees onboarding or the main app using:

- `@AppStorage("onboarding_complete")`

Important nuance:

- onboarding completion is controlled by `AppStorage`, not by reading
  `UserProfile.onboardingComplete`
- there is a `UserProfile.onboardingComplete` field, but it is not the gate for
  showing onboarding

### 5.3 SwiftData schema

The model container includes:

- `FoodEntry`
- `DailyGoal`
- `WeightEntry`
- `ChatMessage`
- `CustomFood`
- `UserProfile`
- `MealTemplate`
- `WaterEntry`
- `LoggingSession`
- `AgentTraceRecord`
- `ResolvedFoodEvidence`

### 5.4 CloudKit mode

If iCloud sync is enabled, the app constructs the model container with:

- `cloudKitDatabase: .automatic`

Otherwise:

- `cloudKitDatabase: .none`

Important nuance:

- the container is decided on app launch
- the settings UI explicitly tells the user to restart after changing sync mode


## 6. Data Model Inventory

This section matters a lot for future LLMs because the app's behavior is built
around these models.

### 6.1 `FoodEntry`

Represents a logged food item.

Fields:

- `id`
- `name`
- `brand`
- `meal`
- `date`
- `portionGrams`
- `portionDescription`
- `calories`
- `proteinG`
- `carbsG`
- `fatG`
- `fiberG`
- `sugarG`
- `sodiumMg`
- `caloriesPer100g`
- `proteinPer100g`
- `carbsPer100g`
- `fatPer100g`
- `fiberPer100g`
- `rawUserInput`
- `fdcId`
- `isFavorite`

Why this model matters:

- it is the canonical persisted food log record
- editing relies on the stored per-100g values
- `rawUserInput` preserves what the user actually said
- `fdcId` links back to a USDA record when available
- `isFavorite` exists, but favorite behavior is not yet surfaced broadly in UI

### 6.2 `DailyGoal`

Represents active calorie and macro targets.

Fields:

- `calories`
- `protein`
- `carbs`
- `fat`
- `fiber`
- `createdAt`
- `isActive`

Important nuance:

- the app typically uses `goals.first`
- there is no sophisticated versioning or selection of multiple active goals

### 6.3 `WeightEntry`

Represents a body-weight log entry.

Fields:

- `date`
- `weightLbs`
- `note`

Also exposes:

- `weightKg` computed from `weightLbs`

### 6.4 `ChatMessage`

Represents one chat bubble in the conversation history.

Fields:

- `role` (`user` or `assistant`)
- `content`
- `timestamp`
- `dayDate`

Important nuance:

- messages are grouped by normalized `dayDate`
- chat history is therefore day-scoped

### 6.5 `CustomFood`

Represents a user-defined food outside USDA.

Fields:

- `name`
- `brand`
- `servingDesc`
- `servingGrams`
- `calories`
- `proteinG`
- `carbsG`
- `fatG`
- `fiberG`
- `createdAt`

This model is used both in UI and in the AI food candidate search path.

### 6.6 `UserProfile`

Represents onboarding/profile information.

Fields:

- `biologicalSex`
- `birthYear`
- `heightInches`
- `activityLevel`
- `weightGoal`
- `onboardingComplete`
- `createdAt`

Important contradiction:

- code comment says this model is "local only, never synced"
- but `UserProfile` is included in the same schema that becomes CloudKit-backed
  when sync is enabled
- there is no explicit exclusion mechanism in the current code

### 6.7 `MealTemplate`

Represents reusable meal templates.

Fields:

- `name`
- `items`
- `createdAt`

`items` is an array of `TemplateItem` structs with:

- `foodName`
- `portionGrams`
- `calories`
- `proteinG`
- `carbsG`
- `fatG`

Important reality check:

- the model exists
- the AI service has template query hooks
- there is currently no visible UI in the shipped views for creating or managing
  meal templates

### 6.8 `WaterEntry`

Represents a water log entry.

Fields:

- `date`
- `amountOz`

### 6.9 `LoggingSession`

Persists AI conversation task state for the current day.

Fields:

- `dayDate`
- `status`
- `serializedState`
- timestamps

`decodedState` exposes the parsed `AgentTaskState`.

This is how clarification state survives across turns.

### 6.10 `AgentTaskState`

Codable struct, not a SwiftData model itself.

Fields:

- `taskId`
- `status`
- `intent`
- `originalUserMessage`
- `latestUserMessage`
- `meal`
- `pendingDescriptions`
- `unresolvedSlots`
- `lastQuestion`
- `correctionTargetName`
- `lastToolContext`
- `candidateGroups`

This is the core working memory object for AI food conversations.

### 6.11 `AgentTraceRecord`

Persists AI execution trace metadata.

Fields include:

- detected intent
- provider type
- fallback usage
- raw model action
- routed action
- final action
- validation summary
- search summary
- candidate summary
- raw model response
- final reply

This is developer/diagnostic infrastructure. There is no user-facing inspector
for it in the app right now.

### 6.12 `ResolvedFoodEvidence`

Stores evidence about how a logged food was resolved.

Fields include:

- `foodEntryId`
- `sourceType`
- `fdcId`
- `matchedName`
- `matchedBrand`
- `searchTerms`
- `candidateSummary`
- `resolutionConfidence`
- `wasClarified`

This is meant to make logged entries auditable after the fact.

### 6.13 Supporting enums and derived types

The models file also defines:

- `BiologicalSex`
- `ActivityLevel`
- `WeightGoal`
- `WeightUnit`
- `NutritionTotals`

`NutritionTotals.from(entries:)` is used widely to compute daily totals without
storing a separate aggregate table.


## 7. Main User Experience and Screen Inventory

### 7.1 Tab structure

The app's main tab bar contains:

1. Chat
2. Log
3. Weight
4. Settings

Default selected tab:

- `chat`

### 7.2 Chat tab

The Chat tab is the flagship workflow.

What it shows:

- macro summary header (`MacroRingsView`)
- recent food quick-add chips when chat is empty
- a goals personalization banner if user is still using default goals
- day-scoped chat conversation
- typing indicator while AI is processing
- barcode scan button
- text field + send button
- date navigator so prior days can be viewed

Important behavior:

- if viewing a past day, the input is disabled and the user sees a read-only
  note telling them to go back to Today to add entries
- clearing chat deletes only chat messages and logging sessions, not food entries

When the user sends a message:

1. keyboard is dismissed
2. user message is stored immediately as a `ChatMessage`
3. recent chat context is built from the last 6 messages
4. recent food history is built from the last 30 days
5. all weight entries are included
6. current goal and active logging session are included
7. `FoodLoggingService.process(...)` is called
8. the returned `LoggingResult` is applied to SwiftData
9. traces/evidence are persisted
10. assistant reply is inserted as a `ChatMessage`

Important architecture point:

- `FoodLoggingService` decides what should happen
- `ChatView.applyAction(...)` actually performs the data mutation in SwiftData

This means the service is a planner/formatter, not the final database writer.

### 7.3 Daily Log tab

The Daily Log tab is a structured view over logged foods.

What it shows:

- macro summary
- water tracker section for today only
- personalization banner
- entries grouped by meal
- calories per meal section
- editable rows with swipe actions
- empty state if nothing logged
- button to add a custom food (today only)

Features:

- date navigator
- grouped meal presentation in order:
  - breakfast
  - lunch
  - dinner
  - snack
- tap row to open editor
- swipe to edit/delete

### 7.4 Weight tab

The Weight tab provides:

- 7-day rolling average
- 30-day chart using Swift Charts
- historical list of up to 50 recent entries
- add/edit/delete weight entries
- unit toggle between lbs and kg

Behavior:

- storage remains in pounds internally
- kg display is derived
- a note can be attached to each weight entry

### 7.5 Settings tab

Settings currently contains:

- Goals
- iCloud Sync
- Custom Foods
- AI Model
- Food Database metadata
- Version / placeholder Privacy Policy / Terms links

Important reality:

- AI Model settings are informational only in the current build
- Apple Intelligence is presented as the active provider
- llama.cpp is not exposed


## 8. Onboarding Flow

Onboarding is a five-step flow:

1. Welcome
2. Basics
3. Goals
4. iCloud
5. All Set

### 8.1 Welcome

Positioning:

- the user can "just say what you ate"
- setup can be skipped entirely

### 8.2 Basics

Collects:

- biological sex
- birth year
- height
- current weight
- activity level

This data is framed as calorie-estimation input.

### 8.3 Goals

Uses `GoalService` to estimate:

- calories
- protein
- carbs
- fat

User can:

- accept suggested values
- edit them before continuing
- skip and use defaults

### 8.4 iCloud

Allows the user to optionally enable iCloud sync.

Important implementation note:

- this screen checks iCloud availability
- if enabled, it calls `syncManager.enableiCloud(...)`
- the code currently constructs a temporary `ModelContainer` inline for that
  enable call instead of reusing the app's real container
- later settings screen uses `modelContext.container`

This is an implementation inconsistency worth noting.

### 8.5 Completion

On finish:

- `UserProfile` is persisted
- current weight is stored as a `WeightEntry` if present
- `onboarding_complete` AppStorage is set to true

Skip path:

- inserts a default `DailyGoal`
- immediately sets `onboarding_complete`
- does not create a full profile


## 9. Goals System

### 9.1 Goal calculations

`GoalService` provides:

- TDEE calculation using Mifflin-St Jeor
- suggested calorie targets based on lose/maintain/gain mode
- suggested macro allocation
- a default goal of:
  - 2000 calories
  - 100g protein
  - 250g carbs
  - 65g fat
  - 25g fiber

### 9.2 Goal editing

`GoalsSettingsView` provides sliders for:

- calories
- protein
- carbs
- fat
- fiber

Also includes:

- "Recalculate from My Info"

### 9.3 Recalculation flow

`RecalculateGoalsView` lets the user enter:

- sex
- birth year
- height
- weight
- activity level
- weight goal

Then applies recalculated values to the current goal or inserts a new one.

Also sets:

- `UserDefaults.standard["goals_personalized"] = true`

### 9.4 Goal personalization banner

`UnpersonalizedGoalsBanner` appears when:

- onboarding is complete
- goals are not marked personalized
- user has not dismissed the banner locally


## 10. Weight Tracking System

### 10.1 Weight entry creation/editing

`WeightLogEntryView` is used for both add and edit.

Features:

- large numeric input
- lbs / kg pill switcher
- one decimal place sanitization
- date/time picker
- optional note

### 10.2 Weight charting

`WeightLoggingView`:

- computes 7-day average from most recent entries
- shows 30-day line chart
- lets user delete/edit entries via swipe
- stores display unit in `@AppStorage("weight_unit")`


## 11. Water Tracking

Water tracking exists inside the Log tab only.

`WaterTrackerSection`:

- reads all `WaterEntry`
- filters to today
- sums ounces
- shows a progress bar to `water_goal_oz`
- offers quick-add buttons:
  - +8 oz
  - +12 oz
  - +16 oz
  - +20 oz

Important nuance:

- there is no dedicated Water tab
- water goal is just an AppStorage scalar, not a model


## 12. Custom Foods

### 12.1 UI

Custom foods can be created from:

- Log tab
- Settings > Custom Foods

### 12.2 Fields

User enters:

- name
- brand
- serving description
- serving grams
- calories
- protein
- carbs
- fat
- fiber

### 12.3 Runtime usage

Custom foods are not just passive records. They are included in:

- chat processing
- candidate search/ranking in `FoodLoggingService`
- settings list management

This means the AI can resolve a custom food if it is lexically relevant.


## 13. Barcode Scanning

Barcode scanning is implemented with `AVFoundation` using a
`UIViewControllerRepresentable`.

Supported metadata types:

- EAN-8
- EAN-13
- UPC-E
- Code 128
- QR
- PDF417

Behavior:

- opens camera preview
- draws scan region overlay
- returns the first decoded code
- looks up barcode via `DatabaseManager.food(byBarcode:)`
- if found, immediately inserts a `FoodEntry`
- if not found, inserts an assistant chat message saying barcode was not found

Important nuance:

- scanner accepts QR/PDF417 too, but the app's handler only meaningfully treats
  the value as a food barcode lookup key


## 14. Local Food Database

Nomva ships with a bundled SQLite database at:

- `Nomva/Resources/foods.sqlite`

### 14.1 Source data

Built from USDA FoodData Central JSON exports:

- SR Legacy
- Branded Foods

### 14.2 Build script

`scripts/build_db.py`:

- finds USDA JSON under `sr_legacy/` and `branded/`
- normalizes wrapped USDA exports
- creates `foods` table
- creates barcode index
- creates FTS5 table `foods_fts`
- inserts SR Legacy foods
- inserts Branded foods
- stores metadata:
  - `total_foods`
  - `build_date`

### 14.3 Nutrition normalization

The builder:

- converts SR Legacy nutrient values from 100g to serving-sized amounts
- prefers `labelNutrients` for branded foods when available
- skips branded foods with zero calorie data

### 14.4 Runtime database access

`DatabaseManager`:

- opens the bundled DB read-only
- applies performance pragmas
- exposes:
  - FTS search
  - loose LIKE search
  - lookup by FDC ID
  - lookup by local row ID
  - lookup by barcode
  - metadata lookup


## 15. AI / LLM Architecture

This is the most important technical section for future LLMs.

Nomva does not have one AI engine. It has multiple layers and fallbacks.

### 15.1 Provider abstraction

`LLMProvider` defines two classes of capability:

1. Legacy generic JSON completion:
   - `complete(systemPrompt:userMessage:recentMessages:)`
2. Focused micro-task methods:
   - `classifyIntent`
   - `splitFoods`
   - `confirmFoodMatch`
   - `extractServings`
   - `extractMeal`
   - `pickDeleteTargets`
   - `estimateGrams`
   - `generalReply`

### 15.2 Active provider

In this build:

- `LLMProviderFactory.active()` always returns `FoundationModelsProvider`

`LlamaCppProvider` exists but is disabled.

Important repo reality:

- a `.gguf` model file exists in the repo
- the app settings describe Apple Intelligence only
- llama runtime is stubbed out and intentionally disabled due to prior runtime
  issues

### 15.3 Foundation Models provider

`FoundationModelsProvider` uses:

- `FoundationModels`
- `LanguageModelSession`
- tiny `@Generable` types for constrained structured outputs

It supports both:

- focused typed methods
- legacy generic JSON generation

It also checks model availability and can throw for:

- unsupported OS
- device not eligible
- Apple Intelligence disabled
- model not ready
- bad model output

### 15.4 AI execution order in `FoodLoggingService.process(...)`

This is the actual runtime order today:

1. Bootstrap or resume `AgentTaskState`
2. Classify Swift-side intent family
3. Try the focused provider pipeline
4. If unresolved and intent is food logging/correction, try the staged food pipeline
5. If still unresolved and intent is food logging, try deterministic direct food log
6. If still unresolved, run the legacy generic JSON loop

This is a key point:

- the app contains several overlapping AI subsystems
- behavior may differ depending on which layer succeeds first


## 16. Focused Pipeline

This is currently the preferred path.

### 16.1 What it handles

Focused pipeline explicitly handles:

- food logging
- food deletion
- data queries
- conversational replies

It intentionally returns `nil` for:

- food edits
- weight logging
- goal setting

Those fall through to older paths.

### 16.2 Intent classification

The focused pipeline first asks the provider to classify intent via a tiny
schema (`IntentCategory`), but with an important override:

- if the app is already mid-clarification for a food flow, it trusts the
  Swift-side intent instead of letting the model reinterpret a short reply as
  small talk

### 16.3 Focused food logging flow

`runFocusedFoodLog(...)` does this:

1. detects whether current turn is a clarification reply
2. chooses an original "servings anchor" so prior quantity survives across turns
3. splits foods only for true multi-item messages
4. resolves meal via provider or fallback
5. for each food mention:
   - builds normalized search query
   - runs local candidate search
   - asks provider to confirm top candidate
   - optionally checks second candidate
   - falls back to confidence threshold if needed
   - extracts servings via provider
   - falls back to direct count parsing
6. creates `FoodLogItem` values
7. calls `resolveAndLog(...)`

Important nuance:

- clarification replies lower the confidence threshold
- clarification replies also bypass guardrail re-questioning to avoid loops

### 16.4 Focused delete flow

`runFocusedDelete(...)`:

- builds a text summary of up to 25 recent entries
- asks provider to choose exact names to delete
- filters provider output to names that actually exist
- returns `.deleteEntry`

### 16.5 Focused query flow

`runFocusedQuery(...)` does not expose the full data universe.
It builds a compact context from:

- current goals
- today's entries
- yesterday's entries
- recent weight entries

Then asks provider for a concise reply.

Important limitation:

- although the UI and overall vision suggest broad querying, the focused query
  path currently answers from a relatively compact synthesized context, not a
  deep arbitrary database inspection tool

### 16.6 Focused conversational reply

`runFocusedReply(...)` is essentially small-talk / general response mode, using:

- today's calories so far
- goal calories
- recent conversation


## 17. Staged Food Pipeline

If the focused pipeline does not handle a food logging/correction turn, the app
tries a second layer: the staged food pipeline.

This pipeline is significantly more explicit than the old generic loop.

### 17.1 Stages

The stages are:

1. `extract`
2. `search_plan`
3. `candidate_select`
4. `portion_resolve`

### 17.2 Stage 1: extract

Goal:

- identify the food item(s), portion phrasing, servings, and meal hint

Allowed outputs are restricted to:

- `log_food`
- `replace_entry`
- `ask_clarification`

### 17.3 Stage 2: search plan

Goal:

- rewrite extracted food mentions into search-friendly database queries

Rules include:

- remove quantity words
- remove meal words
- prefer generic queries unless user specified a variant

### 17.4 Stage 3: candidate select

Goal:

- inspect the textual search results
- choose a `candidate_id`
- or ask clarification
- or trigger a better search

Important recent safeguard:

- if the model identifies the food correctly but fails to emit `candidate_id`,
  the app now tries deterministic candidate binding for obvious high-confidence
  matches

### 17.5 Stage 4: portion resolve

Goal:

- finalize `portion_description`, `servings`, and `meal`

The selected `candidate_id` must remain unchanged in this stage.

### 17.6 Stage trace object

The staged pipeline accumulates:

- provider types
- raw actions
- routed actions
- validations
- raw responses

This data is later attached to `AgentTraceRecord`.


## 18. Deterministic Food Resolution and Search Heuristics

Regardless of which AI layer produced the high-level intent, actual food
resolution still depends heavily on deterministic local search and ranking.

### 18.1 Candidate sources

Food candidates can come from:

- USDA bundled database
- custom foods
- recent logged entries

### 18.2 Candidate search

`searchCandidates(...)`:

1. creates query variants
2. runs strict FTS search
3. runs loose LIKE search
4. merges duplicates
5. adds matching custom food candidates
6. adds matching recent-entry candidates
7. scores all candidates
8. computes confidence values
9. applies special whole-food preference rules

### 18.3 Scoring behavior

Scoring includes:

- exact name matches
- prefix matches
- token overlap
- generic result preference for generic queries
- SR Legacy / whole-food source bonus
- raw/plain form bonus
- tiny-serving penalty for count-based queries
- suspicious form penalties
- brand reference bonus
- custom and recent source bonuses
- plain whole-food penalties for extra/variant concepts

Examples of what the heuristics try to avoid:

- `2 bananas` matching flavored yogurt or dehydrated bananas
- `cheese` matching a processed compound item like `Cheesefurter`
- `bacon` matching `Bacon, Meatless`

### 18.4 Whole-food shortcuts

For plain whole-food queries, the engine prefers:

1. literal whole-food matches
2. simple generic base matches

before accepting noisier ranked results.

### 18.5 Guardrails

Before committing, `guardrailQuestion(...)` may force clarification if:

- confidence is below threshold
- the candidate appears to be a suspicious processed form
- a plain whole-food request resolved to something with extra concept tokens


## 19. Grams Estimation Strategy

When logging food, the app decides portion grams using a priority stack:

1. explicit `estimatedGrams` in item
2. provider `estimateGrams(...)`
3. hardcoded `gramsForPortion(...)`
4. `servings * candidate.servingGrams`
5. default candidate serving grams

### 19.1 Provider estimate

The app will ask the model questions like:

- how many grams is "2 slices of bacon"?

### 19.2 Hardcoded fallback table

If provider grams estimation is unavailable or fails, `gramsForPortion(...)`
contains hardcoded conversions for:

- unit-based conversions:
  - ounce
  - pound
  - gram
  - kilogram
  - tablespoon
  - teaspoon
  - milliliter
  - cup
- food-specific slice/piece heuristics:
  - bacon
  - ham
  - turkey deli meat
  - bread
  - cheese
  - pizza
  - pie
  - cake
  - sliced produce
- whole-item heuristics:
  - egg
  - banana
  - apple

Important reality:

- despite the project's aspiration to let the LLM do most reasoning, there is
  still meaningful hardcoded food-specific logic in this fallback


## 20. Legacy Generic JSON Loop

If newer paths do not resolve the request, the service still has the older
generic loop.

### 20.1 Behavior

This loop:

- builds a large system prompt
- asks the provider for a JSON object
- normalizes and routes actions
- runs pseudo-tools by feeding tool results back as text
- loops up to 6 times

### 20.2 Supported actions in legacy path

Examples include:

- `search_foods`
- `query_log`
- `query_weight`
- `query_goals`
- `query_custom_foods`
- `query_templates`
- `log_food`
- `replace_entry`
- `edit_entry`
- `delete_entry`
- `delete_meal`
- `log_weight`
- `set_goal`
- `ask_clarification`
- `reply`

### 20.3 Why it still exists

Because not every intent has been migrated cleanly into the focused or staged
pipelines yet.

### 20.4 Risk

This means the codebase currently contains overlapping logic paths that can be
hard to reason about.


## 21. Mutation Application Layer

The AI service does not directly mutate SwiftData. `ChatView.applyAction(...)`
does.

### 21.1 Supported mutations from chat

- insert food entries
- replace food entries
- log weight
- edit food portion
- delete food entries
- delete meal
- update goal fields

### 21.2 Replace behavior

Replace flow:

- find entry by fuzzy name matching
- delete wrong entry if found
- insert corrected entries

### 21.3 Edit behavior

Edit flow:

- find best matching entry
- recalculate nutrition from stored per-100g values

### 21.4 Delete behavior

Delete flow:

- can delete across all entries, not only today's

### 21.5 Evidence persistence

If a food log succeeds, `ChatView` persists:

- `ResolvedFoodEvidence`

If the service returned trace data, `ChatView` also persists:

- `AgentTraceRecord`


## 22. Search, History, and Date Scope Behavior

### 22.1 Chat history scope

Chat messages are day-scoped via `dayDate`.

### 22.2 Food history scope passed to AI

Food AI receives:

- last 30 days of entries

### 22.3 Weight history scope passed to AI

Weight AI receives:

- all weight entries

### 22.4 Session scope

Logging sessions are day-scoped and reused only when:

- status is `awaiting_clarification`
- the new turn looks like a real clarification reply

The deterministic eval harness explicitly checks this session reuse logic.


## 23. iCloud / Sync Reality

### 23.1 What the app promises

The UI says:

- your data can sync across Apple devices privately through iCloud

### 23.2 What the code actually does

`SyncManager`:

- stores a boolean flag in `UserDefaults`
- checks `CKContainer.default().accountStatus()`
- toggles `iCloudEnabled`
- sets `syncStatus`

### 23.3 What it does not currently do

- no visible manual sync trigger
- `lastSyncDate` exists but is not meaningfully updated
- no migration/status dashboard
- no conflict handling UI

### 23.4 Operational behavior

Turning sync on/off requires app restart because model container configuration is
decided at app launch.


## 24. Project Configuration and Capabilities

### 24.1 Info.plist highlights

The app declares:

- camera usage for barcode scanning
- photo library usage for meal photo analysis
- iCloud ubiquitous container settings
- Files app document access (`UIFileSharingEnabled`, opening documents in place)

Important reality:

- camera scanning is implemented
- meal photo analysis is not currently implemented anywhere in the app code
- the photo permission string is therefore aspirational / ahead of implementation

### 24.2 Entitlements

The app has:

- CloudKit entitlement
- iCloud container identifier `iCloud.com.nomva.app`
- APS environment set to development

### 24.3 Xcode project resource/linking facts

The project includes:

- `foods.sqlite` in app resources
- `libsqlite3.tbd` in linked frameworks
- `Nomva.entitlements` in code sign settings


## 25. Evaluation and Safety Tooling

### 25.1 Deterministic eval harness

`scripts/run_food_logging_eval.py` is a deterministic test harness that mirrors
core search/session heuristics in Python.

It evaluates:

- intent classification cases
- clarification-session reuse cases
- retrieval quality cases

### 25.2 Current eval themes

The cases focus on historical failure modes such as:

- `2 bananas`
- `two slices of cheese`
- `milk`
- `Frosted Flakes`
- `2% milk`
- `2 slices of bacon`

### 25.3 Why it matters

This harness is not a full app integration test, but it is the project's main
repeatable regression test for search/ranking and session logic.


## 26. Existing Documentation Artifacts

The repo already contains several documentation artifacts:

- `LLM_FOOD_LOGGING_IMPLEMENTATION_SPEC.md`
  - aspirational architecture for a more agentic LLM logging system
- `PROJECT_UPDATE_SUMMARY.txt`
- `PROJECT_UPDATE_SUMMARY.rtf`
- `PROJECT_UPDATE_SUMMARY.pdf`

Important note for future LLMs:

- the spec file is forward-looking
- this report is intended to describe what is actually in the code now


## 27. Important Mismatches, Incomplete Features, and Design Debt

This section is critical. These are areas where intent and implementation do
not fully match.

### 27.1 Multiple AI pipelines coexist

The app currently has:

- focused pipeline
- staged pipeline
- direct deterministic food log
- legacy generic loop

This gives flexibility but also creates complexity and overlap.

### 27.2 Llama provider is disabled

Despite:

- `LLMProviderType.llamaCpp`
- disabled `LlamaCppProvider`
- a `.gguf` file in the repo

the runtime always uses Apple Intelligence in this build.

### 27.3 Photo analysis is not implemented

The plist promises meal-photo analysis, but there is no photo ingestion or
photo-based logging code in the app.

### 27.4 Meal templates exist but are not productized

The data model and query hooks exist, but there is no clear UI flow for users
to create or manage meal templates.

### 27.5 Favorites are stored but underused

`FoodEntry.isFavorite` can be toggled in the edit sheet, but there is no
favorite list, filtering UI, or obvious AI bias from favorites.

### 27.6 UserProfile sync semantics are unclear

The comment says profile is local-only, but schema configuration suggests it may
sync when CloudKit is enabled.

### 27.7 Sync status is shallow

The sync system exposes a toggle and an availability check but not a robust
sync lifecycle UI or observable sync telemetry.

### 27.8 Duplicate food database artifacts exist in repo

The repository contains multiple SQLite/JSON artifacts, including:

- `Nomva/Resources/foods.sqlite`
- `Resources/foods.sqlite`
- `scripts/Resources/foods.sqlite`
- root/sibling USDA JSON copies

The app runtime uses the bundled resource under `Nomva/Resources/foods.sqlite`.

### 27.9 Query capability is narrower than the vision

The product aspires to "full CRUD and question/answer over all the data," but
today's focused query layer answers from compact synthesized context, not a
rich general-purpose query tool surface.


## 28. Working on This Project: Recommended Entry Points for Future LLMs

If another LLM needs to modify this project, the best reading order is:

1. `Nomva/NomvaApp.swift`
2. `Nomva/Models/DataModels.swift`
3. `Nomva/Views/Chat/ChatView.swift`
4. `Nomva/Services/FoodLoggingService.swift`
5. `Nomva/Services/FoundationModelsProvider.swift`
6. `Nomva/Services/DatabaseManager.swift`
7. `Nomva/Views/Log/DailyLogView.swift`
8. `Nomva/Views/Weight/WeightLoggingView.swift`
9. `Nomva/Views/Settings/SettingsView.swift`
10. `scripts/build_db.py`
11. `scripts/run_food_logging_eval.py`

If you only need the food AI path, prioritize:

1. `FoodLoggingService.swift`
2. `FoundationModelsProvider.swift`
3. `DatabaseManager.swift`
4. `ChatView.swift`
5. `Models/FoodItem.swift`
6. `scripts/run_food_logging_eval.py`


## 29. Practical Commands and Workflows

### 29.1 Rebuild the USDA food database

```bash
python3 scripts/build_db.py
```

Expected input folders:

- `sr_legacy/`
- `branded/`

Expected output:

- `Nomva/Resources/foods.sqlite`

### 29.2 Run deterministic food logging evals

```bash
python3 scripts/run_food_logging_eval.py
```

### 29.3 Typical app-side behavior checks

Useful manual scenarios:

- `For breakfast I had 2 bananas`
- `For lunch I had 2 slices of bacon`
- `No, that wasn't right. Just a regular banana.`
- `Delete my lunch`
- `What are my goals?`
- `I weigh 185 lbs`


## 30. Final Mental Model

If you are another LLM entering this repo, the most accurate mental model is:

Nomva is a local-first iOS nutrition tracker that is halfway between:

- a polished consumer calorie tracker
- an experimental AI agent platform for food logging

The app already has:

- good local persistence foundations
- a real USDA search database
- barcode support
- goal and weight tracking
- a meaningful AI routing stack
- trace/evidence infrastructure

But it also still contains:

- overlapping AI architectures
- partially implemented product promises
- dormant or underused models
- some hardcoded heuristics that coexist with the LLM-driven design

The safest way to work in this project is to treat it as a layered system:

1. SwiftUI owns presentation and local mutation application.
2. SwiftData owns persisted app state.
3. SQLite owns canonical food search data.
4. `FoodLoggingService` is the orchestration hub.
5. `FoundationModelsProvider` is the active LLM backend.
6. The AI stack is intentionally defensive and fallback-heavy.

If you change one layer, assume at least one fallback path still depends on the
old behavior until you confirm otherwise.

