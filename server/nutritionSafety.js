"use strict";

// Handle only high-confidence cases before the model. Ordinary food logs and
// nutrition questions continue through the usual flow.
function highRiskReply(message) {
  if (typeof message !== "string") return null;
  const text = message.trim().toLowerCase();
  if (!text) return null;

  if (/\b(anorexia|bulimia|eating disorder|purging|purge|starv(?:e|ing|ation)|make myself throw up|vomit after eating)\b/.test(text)) {
    return "I'm sorry you're dealing with this. I can't help with purging, starvation, or restrictive weight-loss plans. A qualified clinician or eating-disorder specialist can help you make a safe plan. If you feel in immediate danger, seek urgent local help now.";
  }
  if (/\b(pregnan(?:t|cy)|breastfeed(?:ing)?|nurs(?:e|ing))\b/.test(text)
      && /\b(calori(?:e|es)|weight|diet|fast(?:ing)?|nutrition|eat(?:ing)?)\b/.test(text)) {
    return "Pregnancy and breastfeeding change nutritional needs. Nomva's calorie estimates are for adults without those needs; please ask your prenatal or other qualified clinician for an individualized target.";
  }
  if (/\b(allerg(?:y|ic|ies)|anaphylaxis)\b/.test(text)
      && /\b(safe|eat|ingredient|contains|avoid|reaction)\b/.test(text)) {
    return "I can't verify that a food is safe for an allergy. Check the current package label and contact the maker or your clinician if uncertain. If you may be having a severe reaction, use your emergency plan and seek urgent medical help.";
  }
  if (/\b(insulin|diabetes|diabetic|medication|dose|dosage)\b/.test(text)
      && /\b(adjust|change|stop|start|take|how much|treat|dose|dosage)\b/.test(text)) {
    return "I can't advise on medication, insulin, or treatment changes. Please use your clinician's plan or contact a qualified health professional; seek urgent care for severe symptoms.";
  }
  return null;
}

module.exports = { highRiskReply };
