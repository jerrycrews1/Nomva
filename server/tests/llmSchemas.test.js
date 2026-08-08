const assert = require("node:assert/strict");
const test = require("node:test");

const {
  ANALYZE_NUTRITION_LABEL_SCHEMA,
  ANALYZE_PHOTO_SCHEMA,
  structuredOutputForTask,
  TASK_STRUCTURED_OUTPUTS,
} = require("../llmSchemas");

function assertStrictObjects(schema, path = "root") {
  if (!schema || typeof schema !== "object") return;
  if (schema.type === "object") {
    assert.equal(schema.additionalProperties, false, `${path} must reject additional properties`);
    assert.deepEqual(
      [...schema.required].sort(),
      Object.keys(schema.properties).sort(),
      `${path} must require every property for strict structured output`
    );
  }
  for (const [key, value] of Object.entries(schema)) {
    if (key !== "properties" || typeof value !== "object") {
      assertStrictObjects(value, `${path}.${key}`);
      continue;
    }
    for (const [property, propertySchema] of Object.entries(value)) {
      assertStrictObjects(propertySchema, `${path}.${property}`);
    }
  }
}

test("all registered text tasks use strict closed schemas", () => {
  assert.ok(Object.keys(TASK_STRUCTURED_OUTPUTS).length >= 18);
  for (const [task, config] of Object.entries(TASK_STRUCTURED_OUTPUTS)) {
    assert.equal(structuredOutputForTask(task).name, task);
    assertStrictObjects(config.schema, task);
  }
});

test("vision schemas are strict and nullable only where the image can be unreadable", () => {
  assertStrictObjects(ANALYZE_PHOTO_SCHEMA, "analyze_photo");
  assertStrictObjects(ANALYZE_NUTRITION_LABEL_SCHEMA, "analyze_nutrition_label");
});
