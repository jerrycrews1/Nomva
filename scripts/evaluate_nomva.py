import json
import os
import urllib.request
import urllib.error

# ─── TEST PROMPTS ────────────────────────────────────────────────────────────

SIMPLE_PROMPTS = [
    "I had an apple", "Ate 2 bananas for breakfast", "1 cup of coffee", 
    "Log a bowl of oatmeal", "Had 3 slices of bacon", "2 large eggs for breakfast",
    "Glass of orange juice", "Ate a turkey sandwich", "1 slice of cheese",
    "Bowl of cereal with milk", "Had 2 pieces of toast", "Chicken breast for dinner",
    "1 cup of rice", "Ate a protein bar", "Handful of almonds",
    "Log a Greek yogurt", "Had a salad for lunch", "Bottle of water",
    "2 pancakes with syrup", "Ate a cheeseburger", "Slice of pizza",
    "Bowl of pasta", "1 cup of blueberries", "Had a peach",
    "Ate 2 chocolate chip cookies", "Log a glass of milk", "1 tablespoon of peanut butter",
    "Had a baked potato", "Ate 6 chicken nuggets", "1 cup of broccoli",
    "Bowl of soup", "Had a bagel with cream cheese", "Ate a banana",
    "1 cup of green tea", "Log a steak for dinner", "Had 2 tacos",
    "Ate a burrito", "1 slice of watermelon", "Had a handful of grapes",
    "Ate a muffin", "Log 1 cup of cottage cheese", "Had a ham sandwich",
    "Ate a pear", "1 cup of strawberries", "Had a protein shake",
    "Ate a slice of cake", "Log 2 sausages", "Had a bowl of chili",
    "Ate an omelet", "1 cup of carrots"
]

COMPLEX_PROMPTS = [
    "For lunch I had two slices of white toast with peanut butter on them.",
    "I had 3 eggs and 2 slices of bacon for breakfast, and a glass of OJ.",
    "Actually, I only had half of that apple I logged earlier.",
    "Add a chicken salad with ranch dressing and a side of crackers.",
    "I had a large latte with oat milk and 2 pumps of vanilla syrup.",
    "Change my breakfast to just 1 egg instead of 2.",
    "Delete my lunch and add a Chipotle burrito bowl with double chicken.",
    "I ate a 6oz steak, a baked potato with sour cream, and some asparagus.",
    "Had 2 slices of pepperoni pizza and a diet coke for dinner.",
    "For breakfast I had a smoothie with protein powder, spinach, and half a banana.",
    "Log a turkey club sandwich but without the mayo.",
    "I had a bowl of spaghetti with 3 meatballs and some parmesan cheese.",
    "Add 2 pancakes, 1 sausage link, and a small side of fruit.",
    "I had a handful of mixed nuts and a string cheese as a snack.",
    "Actually it was 2 slices of toast, not 3.",
    "Log my weight as 185.5 lbs today.",
    "What are my macro goals for today?",
    "How many calories have I had so far?",
    "Delete all the food I logged for dinner last night.",
    "I had a tuna melt sandwich and a cup of tomato soup for lunch.",
    "Add a grilled cheese sandwich made with 2 slices of cheddar.",
    "I had 1.5 cups of white rice with some soy sauce.",
    "Log a double espresso and a croissant.",
    "I ate half a rotisserie chicken and some coleslaw.",
    "Change my calorie goal to 1800.",
    "How much protein did I have yesterday?",
    "I had 2 beers and some nachos while watching the game.",
    "Add a bowl of Greek yogurt with honey and granola.",
    "I had a salmon fillet with a squeeze of lemon and some quinoa.",
    "Log 3 small street tacos with carnitas and salsa.",
    "I had a green apple and a tablespoon of almond butter.",
    "Actually, I didn't have the bacon, just the eggs.",
    "Add 2 slices of avocado toast with a fried egg on top.",
    "I had a bowl of ramen with pork and a soft boiled egg.",
    "Log a Caesar salad with grilled shrimp.",
    "I had 2 squares of dark chocolate and a glass of red wine.",
    "Change that peanut butter to 2 tablespoons instead of 1.",
    "I had a blueberry muffin and a small orange juice.",
    "Log a bagel with lox, cream cheese, and capers.",
    "I had a chicken stir fry with peppers, onions, and snap peas.",
    "Add a protein shake made with 1 scoop of whey and 12oz of water.",
    "I had 2 slices of whole wheat bread with 1/4 an avocado.",
    "Log a Cobb salad with blue cheese dressing.",
    "I had a bowl of oatmeal with 1/2 cup of blueberries and some cinnamon.",
    "Actually, delete the crackers I added to my lunch.",
    "I had a turkey burger (no bun) and a side salad.",
    "Add 3 slices of deli turkey and 1 slice of swiss cheese.",
    "I had a cup of lentil soup and a small piece of sourdough bread.",
    "Log a green smoothie with kale, cucumber, and green apple.",
    "I had a slice of pumpkin pie with a dollop of whipped cream."
]

# ─── EVALUATION LOGIC ────────────────────────────────────────────────────────

SYSTEM_PROMPT = """
YOU MUST OUTPUT ONE JSON OBJECT ONLY. NO MARKDOWN. NO TEXT.

ACTIONS SCHEMAS:
- Search: {"action":"search","reasoning":"Identify all items...","queries":[{"q":"food","description":"user segment","meal":"lunch"}]}
- Log: {"action":"log_food","reasoning":"2 slices (2x28g) = 56g...","items":[{"candidate_id":"ID","portion_description":"desc","servings":1.0,"meal":"lunch"}]}
- Edit: {"action":"edit_entry","food_name":"EXACT_NAME_FROM_LOG","new_portion_grams":100,"new_portion_description":"user's new portion words"}
- Delete: {"action":"delete_entry","food_names":["NAME_FROM_LOG"]}
- Reply: {"action":"reply","text":"answer"}

STRICT RULES:
1. MULTI-ITEM: If user says "X with Y", you MUST search for BOTH X and Y in the same turn.
2. SEARCH FIRST: You MUST use "search" for every new item. NEVER guess an ID.
3. MATH: Use the "serving_size" and "hints" in results. 
   - If result is "100g" and user says "2 slices", use the hint "1 slice ≈ 28g" to calculate: (2 * 28) / 100 = 0.56 servings.
   - Explain your math in the "reasoning" field.
"""

API_KEY = os.getenv("OPENAI_API_KEY")

def call_llm(user_message, history=[]):
    if not API_KEY:
        return json.dumps({"error": "Missing OPENAI_API_KEY environment variable"})
    
    url = "https://api.openai.com/v1/chat/completions"
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    messages.extend(history)
    messages.append({"role": "user", "content": user_message})

    payload = {
        "model": "gpt-4o-mini",
        "messages": messages,
        "response_format": {"type": "json_object"},
        "temperature": 0.0
    }

    req = urllib.request.Request(url, data=json.dumps(payload).encode('utf-8'))
    req.add_header('Authorization', f'Bearer {API_KEY}')
    req.add_header('Content-Type', 'application/json')

    try:
        with urllib.request.urlopen(req) as response:
            res_data = json.loads(response.read().decode('utf-8'))
            return res_data['choices'][0]['message']['content']
    except Exception as e:
        return json.dumps({"error": str(e)})

def run_test_suite(prompts, suite_name):
    print(f"\n🚀 RUNNING {suite_name} SUITE...")
    results = []
    for i, p in enumerate(prompts):
        print(f"[{i+1}/{len(prompts)}] Testing: {p}")
        raw = call_llm(p)
        try:
            parsed = json.loads(raw)
            if "error" in parsed:
                print(f"  ❌ Error: {parsed['error']}")
                results.append({"prompt": p, "error": parsed["error"]})
            else:
                results.append({"prompt": p, "response": parsed})
        except Exception as e:
            results.append({"prompt": p, "error": f"Failed to parse JSON: {str(e)}", "raw": raw})
    return results

def grade_results(results):
    score = 0
    total = len(results)
    if total == 0: return 0
    
    failures = []
    for r in results:
        if "error" in r: 
            failures.append(f"PROMPT: {r['prompt']}\nERROR: {r['error']}\n")
            continue
            
        action = r['response'].get("action", "").lower()
        prompt = r['prompt'].lower()
        passed = False
        
        if "delete" in prompt or "remove" in prompt:
            if action == "delete_entry": passed = True
        elif "goal" in prompt:
            if action in ["set_goal", "reply", "search"]: passed = True
        elif "calories" in prompt or "protein" in prompt or "macro" in prompt:
            if action in ["reply", "query_log"]: passed = True
        elif "actually" in prompt or "change" in prompt:
            if action in ["edit_entry", "replace_entry", "delete_entry"]: passed = True
        elif "weight" in prompt:
            if action in ["log_weight", "reply"]: passed = True
        else:
            if action == "search": passed = True
            
        if passed:
            score += 1
        else:
            failures.append(f"❌ FAILED: {r['prompt']}\n   RECEIVED: {json.dumps(r['response'], indent=2)}\n")
    
    percent = (score / total) * 100
    print(f"\n📊 SCORE: {score}/{total} ({percent:.1f}%)")
    
    if failures:
        print("\n📝 FAILURE LOG:")
        for f in failures:
            print(f)
            
    return percent

if __name__ == "__main__":
    if not API_KEY:
        print("❌ ERROR: OPENAI_API_KEY environment variable not found.")
        exit(1)
        
    simple_results = run_test_suite(SIMPLE_PROMPTS, "SIMPLE")
    complex_results = run_test_suite(COMPLEX_PROMPTS, "COMPLEX")
    
    print("\n" + "="*50)
    print("FINAL GRADES")
    print("="*50)
    print("SIMPLE SUITE:", end="")
    grade_results(simple_results)
    print("COMPLEX SUITE:", end="")
    grade_results(complex_results)
