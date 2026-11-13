// SM-2 spaced repetition (simplified). grade: 0 (forgot) .. 5 (perfect)
export interface CardState {
  ease: number;
  interval_days: number;
  repetitions: number;
}

export function review(card: CardState, grade: number): CardState & { due_in_days: number } {
  let { ease, interval_days, repetitions } = card;
  if (grade < 3) {
    repetitions = 0;
    interval_days = 0; // see it again today (in 10 minutes)
  } else {
    repetitions += 1;
    if (repetitions === 1) interval_days = 1;
    else if (repetitions === 2) interval_days = 6;
    else interval_days = Math.round(interval_days * ease);
  }
  ease = Math.max(1.3, ease + (0.1 - (5 - grade) * (0.08 + (5 - grade) * 0.02)));
  return { ease: Number(ease.toFixed(2)), interval_days, repetitions, due_in_days: interval_days };
}
