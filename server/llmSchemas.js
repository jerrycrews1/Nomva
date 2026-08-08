function objectSchema(properties) {
  return {
    type: "object",
    additionalProperties: false,
    properties,
    required: Object.keys(properties),
  };
}

function nullable(schema) {
  return { anyOf: [schema, { type: "null" }] };
}

const string = { type: "string" };
const number = { type: "number" };
const integer = { type: "integer" };
const boolean = { type: "boolean" };
const nullableString = nullable(string);
const nullableNumber = nullable(number);
const nullableInteger = nullable(integer);

const servingSchema = objectSchema({
  servings: number,
  portionDescription: string,
  servingUnit: string,
  confident: boolean,
  hasExplicitPortion: boolean,
});

const TASK_STRUCTURED_OUTPUTS = {
  classify_intent: {
    schema: objectSchema({
      intent: {
        type: "string",
        enum: [
          "log_food",
          "delete_food",
          "edit_food",
          "move_food",
          "query_data",
          "log_weight",
          "log_water",
          "set_goal",
          "reply",
        ],
      },
    }),
    reasoningEffort: "none",
  },
  split_foods: {
    schema: objectSchema({ foods: { type: "array", items: string } }),
    reasoningEffort: "none",
  },
  build_food_search_query: {
    schema: objectSchema({ query: string }),
    reasoningEffort: "none",
  },
  choose_food_candidate: {
    schema: objectSchema({ candidateIndex: nullableInteger }),
    reasoningEffort: "none",
  },
  validate_food_candidate: {
    schema: objectSchema({
      keepCurrentCandidate: boolean,
      servings: number,
      portionDescription: string,
      servingUnit: string,
      confident: boolean,
      hasExplicitPortion: boolean,
      replacementSearchQuery: nullableString,
    }),
    reasoningEffort: "none",
  },
  confirm_match: {
    schema: objectSchema({ isMatch: boolean }),
    reasoningEffort: "none",
  },
  extract_servings: {
    schema: servingSchema,
    reasoningEffort: "none",
  },
  extract_meal: {
    schema: objectSchema({
      meal: { type: "string", enum: ["breakfast", "lunch", "dinner", "snack", "none"] },
    }),
    reasoningEffort: "none",
  },
  extract_water_mutation: {
    schema: objectSchema({
      action: { type: "string", enum: ["add", "delete_all", "update_total", "reply"] },
      amountOz: nullableNumber,
    }),
    reasoningEffort: "none",
  },
  extract_weight_mutation: {
    schema: objectSchema({
      action: { type: "string", enum: ["add", "update", "delete", "delete_all", "reply"] },
      weightLbs: nullableNumber,
      dateHint: nullable({ type: "string", enum: ["today", "yesterday", "latest"] }),
    }),
    reasoningEffort: "none",
  },
  extract_food_move: {
    schema: objectSchema({
      foodName: nullableString,
      destinationMeal: nullable({ type: "string", enum: ["breakfast", "lunch", "dinner", "snack"] }),
      moveAll: boolean,
      sourceMeal: nullable({ type: "string", enum: ["breakfast", "lunch", "dinner", "snack"] }),
      clarificationQuestion: nullableString,
    }),
    reasoningEffort: "low",
  },
  pick_delete_targets: {
    schema: objectSchema({ foodNames: { type: "array", items: string } }),
    reasoningEffort: "low",
  },
  pick_edit_target: {
    schema: objectSchema({
      foodName: nullableString,
      clarificationQuestion: nullableString,
    }),
    reasoningEffort: "low",
  },
  resolve_edit_request: {
    schema: objectSchema({
      servings: number,
      portionDescription: string,
      servingUnit: string,
      confident: boolean,
      hasExplicitPortion: boolean,
      clarificationQuestion: nullableString,
      replacementSearchQuery: nullableString,
    }),
    reasoningEffort: "low",
  },
  estimate_grams: {
    schema: objectSchema({ grams: number }),
    reasoningEffort: "none",
  },
  extract_goal: {
    schema: objectSchema({
      changes: {
        type: "array",
        items: objectSchema({
          metric: {
            type: "string",
            enum: ["calories", "protein", "carbs", "fat", "fiber", "water_oz", "target_weight_lbs"],
          },
          operation: { type: "string", enum: ["set", "increase", "decrease"] },
          value: number,
        }),
      },
    }),
    reasoningEffort: "none",
  },
  parse_data_query: {
    schema: objectSchema({
      queries: {
        type: "array",
        items: objectSchema({
          metric: { type: "string", enum: ["calories", "protein", "carbs", "fat", "fiber", "water", "weight"] },
          aggregation: { type: "string", enum: ["total", "average", "remaining", "latest", "change", "trend"] },
          window: { type: "string", enum: ["selected_day", "last_n_days"] },
          days: nullableInteger,
        }),
      },
    }),
    reasoningEffort: "low",
  },
  general_reply: {
    schema: objectSchema({ text: string }),
    reasoningEffort: "low",
  },
  rank_recent_foods: {
    schema: objectSchema({ candidateIds: { type: "array", items: string } }),
    reasoningEffort: "low",
  },
};

const ANALYZE_PHOTO_SCHEMA = objectSchema({
  notFood: boolean,
  foods: {
    type: "array",
    items: objectSchema({
      name: string,
      portion: string,
      grams: number,
      calories: number,
      protein: number,
      carbs: number,
      fat: number,
      fiber: number,
    }),
  },
});

const ANALYZE_NUTRITION_LABEL_SCHEMA = objectSchema({
  notNutritionLabel: boolean,
  food: nullable(objectSchema({
    name: string,
    brand: string,
    servingDescription: string,
    servingGrams: nullableNumber,
    calories: nullableNumber,
    protein: nullableNumber,
    carbs: nullableNumber,
    fat: nullableNumber,
    fiber: nullableNumber,
  })),
});

function structuredOutputForTask(task) {
  const entry = TASK_STRUCTURED_OUTPUTS[task];
  if (!entry) return null;
  return {
    name: String(task).slice(0, 64),
    ...entry,
  };
}

module.exports = {
  ANALYZE_NUTRITION_LABEL_SCHEMA,
  ANALYZE_PHOTO_SCHEMA,
  structuredOutputForTask,
  TASK_STRUCTURED_OUTPUTS,
};
