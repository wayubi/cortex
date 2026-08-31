#!/usr/bin/env python3
"""
Quality benchmark: 25 random questions across subjects.
Asks both Q8 and Q4 LFM2.5 models, scores which answers more correctly.
"""
import json
import subprocess
import time
import re
import sys

QUESTIONS = [
    # Math
    {"q": "What is 17 * 23?", "a": "391", "subject": "math"},
    {"q": "What is the derivative of x^3 + 2x?", "a": "3x^2 + 2", "subject": "math"},
    {"q": "What is the square root of 144?", "a": "12", "subject": "math"},
    {"q": "Solve for x: 2x + 5 = 13", "a": "4", "subject": "math"},
    {"q": "What is the area of a circle with radius 5? (exact value)", "a": "25π", "subject": "math"},

    # Science
    {"q": "What is the chemical symbol for gold?", "a": "Au", "subject": "science"},
    {"q": "What planet is known as the Red Planet?", "a": "Mars", "subject": "science"},
    {"q": "What is the speed of light in meters per second?", "a": "3.0 × 10^8", "subject": "science"},
    {"q": "What is the powerhouse of the cell?", "a": "mitochondria", "subject": "science"},
    {"q": "What gas do plants absorb from the atmosphere?", "a": "carbon dioxide", "subject": "science"},

    # History
    {"q": "In what year did World War II end?", "a": "1945", "subject": "history"},
    {"q": "Who was the first president of the United States?", "a": "George Washington", "subject": "history"},
    {"q": "What empire built the Colosseum in Rome?", "a": "Roman Empire", "subject": "history"},
    {"q": "In what year did the Berlin Wall fall?", "a": "1989", "subject": "history"},
    {"q": "Who wrote the Declaration of Independence?", "a": "Thomas Jefferson", "subject": "history"},

    # Geography
    {"q": "What is the capital of Japan?", "a": "Tokyo", "subject": "geography"},
    {"q": "What is the largest ocean on Earth?", "a": "Pacific Ocean", "subject": "geography"},
    {"q": "What river is the longest in the world?", "a": "Nile", "subject": "geography"},
    {"q": "What country has the most people?", "a": "India", "subject": "geography"},
    {"q": "What is the smallest country in the world by area?", "a": "Vatican City", "subject": "geography"},

    # Literature
    {"q": "Who wrote 'Romeo and Juliet'?", "a": "Shakespeare", "subject": "literature"},
    {"q": "What is the first book of the Bible?", "a": "Genesis", "subject": "literature"},
    {"q": "Who wrote '1984'?", "a": "George Orwell", "subject": "literature"},
    {"q": "What is the name of the hobbit in 'The Hobbit'?", "a": "Bilbo Baggins", "subject": "literature"},
    {"q": "Who wrote 'The Great Gatsby'?", "a": "F. Scott Fitzgerald", "subject": "literature"},
]

def ask_model(model, question):
    """Send question to model, return response text."""
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": question}],
        "max_tokens": 512,
        "temperature": 0.1
    })
    result = subprocess.run(
        ["curl", "-s", "-X", "POST", "http://localhost:8080/v1/chat/completions",
         "-H", "Content-Type: application/json", "-d", payload],
        capture_output=True, text=True, timeout=120
    )
    try:
        data = json.loads(result.stdout)
        if "choices" in data:
            content = data["choices"][0]["message"]["content"]
            # Strip thinking tags if present
            content = re.sub(r'<\|channel\|>thought\n.*?<channel\|>', '', content, flags=re.DOTALL)
            content = re.sub(r'<\|channel\|>', '', content)
            return content.strip()
        else:
            return f"ERROR: {result.stdout[:200]}"
    except Exception as e:
        return f"ERROR: {e}"

def check_answer(response, expected):
    """Check if response contains the expected answer (fuzzy match)."""
    response_lower = response.lower()
    expected_lower = expected.lower()
    # Direct match
    if expected_lower in response_lower:
        return True
    # Check for key words
    for word in expected_lower.split():
        if len(word) > 2 and word not in response_lower:
            break
    else:
        return True
    # Special cases
    if "3x^2 + 2" in expected and ("3x^2 + 2" in response or "3x² + 2" in response):
        return True
    if "25π" in expected and ("25π" in response or "25 pi" in response or "78.5" in response):
        return True
    if "3.0" in expected and ("3.0 × 10^8" in response or "3.0×10^8" in response or "299,792,458" in response or "300,000" in response):
        return True
    if "india" in expected_lower and "india" in response_lower:
        return True
    if "vatican" in expected_lower and "vatican" in response_lower:
        return True
    return False

def run_benchmark(model, label):
    """Run all questions against a model, return results."""
    results = []
    for i, qa in enumerate(QUESTIONS):
        print(f"  [{label}] Q{i+1}/25: {qa['q'][:50]}...", end=" ", flush=True)
        response = ask_model(model, qa["q"])
        correct = check_answer(response, qa["a"])
        results.append({"question": qa["q"], "expected": qa["a"], "response": response, "correct": correct})
        print("✓" if correct else "✗")
        time.sleep(0.5)  # small delay between requests
    return results

def main():
    q8_model = "lfm2.5-8b-a1b-q8-think-16k"
    q4_model = "lfm2.5-8b-a1b-q4-think-16k"

    print("=" * 60)
    print("QUALITY BENCHMARK: Q8 vs Q4 (25 questions)")
    print("=" * 60)

    # Run Q8
    print(f"\n--- {q8_model} ---")
    q8_results = run_benchmark(q8_model, "Q8")

    # Run Q4
    print(f"\n--- {q4_model} ---")
    q4_results = run_benchmark(q4_model, "Q4")

    # Score
    q8_correct = sum(1 for r in q8_results if r["correct"])
    q4_correct = sum(1 for r in q4_results if r["correct"])

    print("\n" + "=" * 60)
    print("RESULTS")
    print("=" * 60)
    print(f"Q8: {q8_correct}/25 correct")
    print(f"Q4: {q4_correct}/25 correct")

    # Per-subject breakdown
    subjects = list(set(qa["subject"] for qa in QUESTIONS))
    print("\n--- Per Subject ---")
    for subj in sorted(subjects):
        q8_subj = sum(1 for r, qa in zip(q8_results, QUESTIONS) if qa["subject"] == subj and r["correct"])
        q4_subj = sum(1 for r, qa in zip(q4_results, QUESTIONS) if qa["subject"] == subj and r["correct"])
        q8_total = sum(1 for qa in QUESTIONS if qa["subject"] == subj)
        print(f"  {subj:15s}: Q8 {q8_subj}/{q8_total}, Q4 {q4_subj}/{q8_total}")

    # Show disagreements
    print("\n--- Disagreements ---")
    for i, (q8r, q4r) in enumerate(zip(q8_results, q4_results)):
        if q8r["correct"] != q4r["correct"]:
            winner = "Q8" if q8r["correct"] else "Q4"
            print(f"  Q{i+1}: {QUESTIONS[i]['q'][:60]}")
            print(f"    Winner: {winner}")
            print(f"    Q8: {q8r['response'][:100]}")
            print(f"    Q4: {q4r['response'][:100]}")

    # Save full results
    output = {
        "q8_model": q8_model,
        "q4_model": q4_model,
        "q8_score": q8_correct,
        "q4_score": q4_correct,
        "q8_results": q8_results,
        "q4_results": q4_results,
    }
    with open("/tmp/lfm_quality_benchmark.json", "w") as f:
        json.dump(output, f, indent=2)
    print(f"\nFull results saved to /tmp/lfm_quality_benchmark.json")

if __name__ == "__main__":
    main()
