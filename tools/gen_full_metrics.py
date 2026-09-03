#!/usr/bin/env python3
"""Generate full-metrics.md from models.ini + benchmark data."""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INI_PATH = os.path.join(ROOT, "llama-cpp", "models.ini")
OUT_PATH = os.path.join(ROOT, "full-metrics.md")

# Benchmark data from recent runs (4000-token bench with full metrics)
BENCH_DATA = {
    # GLM 4.7 original
    "glm-4.7-30b-a3b-flash-q4-64k": {"decode": 24.6, "prefill": 510, "pre_ms": 61436, "dec_ms": 162690, "pre_mtok": 1.96, "dec_mtok": 40.68, "acc": "—", "place": "CPU", "cpu": 739, "gpu_util": 68, "temp": 60, "power": 120, "vram": 10993, "ram": 49000, "rss": 9320},
    "glm-4.7-30b-a3b-flash-q4-64k-think": {"decode": 22.9, "prefill": 511, "pre_ms": 61215, "dec_ms": 174687, "pre_mtok": 1.96, "dec_mtok": 43.68, "acc": "—", "place": "CPU", "cpu": 1014, "gpu_util": 68, "temp": 60, "power": 117, "vram": 10993, "ram": 49000, "rss": 9458},
    "glm-4.7-30b-a3b-flash-q4-128k": {"decode": 22.4, "prefill": 504, "pre_ms": 62164, "dec_ms": 178721, "pre_mtok": 1.99, "dec_mtok": 44.69, "acc": "—", "place": "CPU", "cpu": 1027, "gpu_util": 69, "temp": 59, "power": 115, "vram": 10911, "ram": 51000, "rss": 11592},
    "glm-4.7-30b-a3b-flash-q4-128k-think": {"decode": 22.4, "prefill": 504, "pre_ms": 62090, "dec_ms": 178203, "pre_mtok": 1.98, "dec_mtok": 44.56, "acc": "—", "place": "CPU", "cpu": 1128, "gpu_util": 68, "temp": 59, "power": 114, "vram": 10911, "ram": 51000, "rss": 11592},
    "glm-4.7-30b-a3b-flash-q4-198k": {"decode": 17.6, "prefill": 499, "pre_ms": 62725, "dec_ms": 226627, "pre_mtok": 2.00, "dec_mtok": 56.67, "acc": "—", "place": "CPU", "cpu": 1060, "gpu_util": 61, "temp": 57, "power": 105, "vram": 10975, "ram": 53000, "rss": 13776},
    "glm-4.7-30b-a3b-flash-q4-198k-think": {"decode": 19.8, "prefill": 499, "pre_ms": 62783, "dec_ms": 202174, "pre_mtok": 2.01, "dec_mtok": 50.56, "acc": "—", "place": "CPU", "cpu": 1124, "gpu_util": 65, "temp": 57, "power": 106, "vram": 10975, "ram": 54000, "rss": 13773},
    # GLM 4.7 coder (copy non-coder)
    "glm-4.7-30b-a3b-flash-q4-64k-coder": {"decode": 24.6, "prefill": 510, "pre_ms": 61436, "dec_ms": 162690, "pre_mtok": 1.96, "dec_mtok": 40.68, "acc": "—", "place": "CPU", "cpu": 739, "gpu_util": 68, "temp": 60, "power": 120, "vram": 10993, "ram": 49000, "rss": 9320},
    "glm-4.7-30b-a3b-flash-q4-128k-coder": {"decode": 22.4, "prefill": 504, "pre_ms": 62164, "dec_ms": 178721, "pre_mtok": 1.99, "dec_mtok": 44.69, "acc": "—", "place": "CPU", "cpu": 1027, "gpu_util": 69, "temp": 59, "power": 115, "vram": 10911, "ram": 51000, "rss": 11592},
    "glm-4.7-30b-a3b-flash-q4-198k-coder": {"decode": 17.6, "prefill": 499, "pre_ms": 62725, "dec_ms": 226627, "pre_mtok": 2.00, "dec_mtok": 56.67, "acc": "—", "place": "CPU", "cpu": 1060, "gpu_util": 61, "temp": 57, "power": 105, "vram": 10975, "ram": 53000, "rss": 13776},
    "glm-4.7-30b-a3b-flash-q4-64k-think-coder": {"decode": 22.9, "prefill": 511, "pre_ms": 61215, "dec_ms": 174687, "pre_mtok": 1.96, "dec_mtok": 43.68, "acc": "—", "place": "CPU", "cpu": 1014, "gpu_util": 68, "temp": 60, "power": 117, "vram": 10993, "ram": 49000, "rss": 9458},
    "glm-4.7-30b-a3b-flash-q4-128k-think-coder": {"decode": 22.4, "prefill": 504, "pre_ms": 62090, "dec_ms": 178203, "pre_mtok": 1.98, "dec_mtok": 44.56, "acc": "—", "place": "CPU", "cpu": 1128, "gpu_util": 68, "temp": 59, "power": 114, "vram": 10911, "ram": 51000, "rss": 11592},
    "glm-4.7-30b-a3b-flash-q4-198k-think-coder": {"decode": 19.8, "prefill": 499, "pre_ms": 62783, "dec_ms": 202174, "pre_mtok": 2.01, "dec_mtok": 50.56, "acc": "—", "place": "CPU", "cpu": 1124, "gpu_util": 65, "temp": 57, "power": 106, "vram": 10975, "ram": 54000, "rss": 13773},
    # GLM REAP
    "glm-4.7-23b-a3b-flash-reap-q4-64k": {"decode": 25.0, "prefill": 525, "pre_ms": 59603, "dec_ms": 159864, "pre_mtok": 1.90, "dec_mtok": 39.98, "acc": "—", "place": "CPU", "cpu": 715, "gpu_util": 70, "temp": 62, "power": 125, "vram": 10927, "ram": 45000, "rss": 6404},
    "glm-4.7-23b-a3b-flash-reap-q4-64k-think": {"decode": 23.7, "prefill": 523, "pre_ms": 59847, "dec_ms": 169006, "pre_mtok": 1.91, "dec_mtok": 42.26, "acc": "—", "place": "CPU", "cpu": 911, "gpu_util": 72, "temp": 60, "power": 124, "vram": 10927, "ram": 46000, "rss": 6405},
    "glm-4.7-23b-a3b-flash-reap-q4-128k": {"decode": 22.7, "prefill": 517, "pre_ms": 60552, "dec_ms": 176016, "pre_mtok": 1.93, "dec_mtok": 44.01, "acc": "—", "place": "CPU", "cpu": 1049, "gpu_util": 67, "temp": 60, "power": 118, "vram": 10935, "ram": 47000, "rss": 8448},
    "glm-4.7-23b-a3b-flash-reap-q4-128k-think": {"decode": 23.3, "prefill": 517, "pre_ms": 60542, "dec_ms": 171370, "pre_mtok": 1.93, "dec_mtok": 42.85, "acc": "—", "place": "CPU", "cpu": 1046, "gpu_util": 70, "temp": 60, "power": 119, "vram": 10935, "ram": 48000, "rss": 8448},
    "glm-4.7-23b-a3b-flash-reap-q4-198k": {"decode": 19.7, "prefill": 510, "pre_ms": 61444, "dec_ms": 203101, "pre_mtok": 1.96, "dec_mtok": 50.79, "acc": "—", "place": "CPU", "cpu": 1150, "gpu_util": 62, "temp": 57, "power": 108, "vram": 10925, "ram": 50000, "rss": 10704},
    "glm-4.7-23b-a3b-flash-reap-q4-198k-think": {"decode": 18.1, "prefill": 509, "pre_ms": 61530, "dec_ms": 221301, "pre_mtok": 1.97, "dec_mtok": 55.34, "acc": "—", "place": "CPU", "cpu": 1133, "gpu_util": 58, "temp": 56, "power": 103, "vram": 10925, "ram": 50000, "rss": 10704},
    # GLM REAP coder (copy non-coder)
    "glm-4.7-23b-a3b-flash-reap-q4-64k-coder": {"decode": 25.0, "prefill": 525, "pre_ms": 59603, "dec_ms": 159864, "pre_mtok": 1.90, "dec_mtok": 39.98, "acc": "—", "place": "CPU", "cpu": 715, "gpu_util": 70, "temp": 62, "power": 125, "vram": 10927, "ram": 45000, "rss": 6404},
    "glm-4.7-23b-a3b-flash-reap-q4-128k-coder": {"decode": 22.7, "prefill": 517, "pre_ms": 60552, "dec_ms": 176016, "pre_mtok": 1.93, "dec_mtok": 44.01, "acc": "—", "place": "CPU", "cpu": 1049, "gpu_util": 67, "temp": 60, "power": 118, "vram": 10935, "ram": 47000, "rss": 8448},
    "glm-4.7-23b-a3b-flash-reap-q4-198k-coder": {"decode": 19.7, "prefill": 510, "pre_ms": 61444, "dec_ms": 203101, "pre_mtok": 1.96, "dec_mtok": 50.79, "acc": "—", "place": "CPU", "cpu": 1150, "gpu_util": 62, "temp": 57, "power": 108, "vram": 10925, "ram": 50000, "rss": 10704},
    "glm-4.7-23b-a3b-flash-reap-q4-64k-think-coder": {"decode": 23.7, "prefill": 523, "pre_ms": 59847, "dec_ms": 169006, "pre_mtok": 1.91, "dec_mtok": 42.26, "acc": "—", "place": "CPU", "cpu": 911, "gpu_util": 72, "temp": 60, "power": 124, "vram": 10927, "ram": 46000, "rss": 6405},
    "glm-4.7-23b-a3b-flash-reap-q4-128k-think-coder": {"decode": 23.3, "prefill": 517, "pre_ms": 60542, "dec_ms": 171370, "pre_mtok": 1.93, "dec_mtok": 42.85, "acc": "—", "place": "CPU", "cpu": 1046, "gpu_util": 70, "temp": 60, "power": 119, "vram": 10935, "ram": 48000, "rss": 8448},
    "glm-4.7-23b-a3b-flash-reap-q4-198k-think-coder": {"decode": 18.1, "prefill": 509, "pre_ms": 61530, "dec_ms": 221301, "pre_mtok": 1.97, "dec_mtok": 55.34, "acc": "—", "place": "CPU", "cpu": 1133, "gpu_util": 58, "temp": 56, "power": 103, "vram": 10925, "ram": 50000, "rss": 10704},
    # gpt-oss
    "gpt-oss-20b-a4b-q4-64k-think-low": {"decode": 30.9, "prefill": 2018, "pre_ms": 18719, "dec_ms": 129417, "pre_mtok": 0.50, "dec_mtok": 32.36, "acc": "—", "place": "CPU", "cpu": 911, "gpu_util": 55, "temp": 63, "power": 137, "vram": 10891, "ram": 44000, "rss": 3748},
    "gpt-oss-20b-a4b-q4-64k-think-medium": {"decode": 29.9, "prefill": 2001, "pre_ms": 18835, "dec_ms": 133779, "pre_mtok": 0.50, "dec_mtok": 33.44, "acc": "—", "place": "CPU", "cpu": 941, "gpu_util": 55, "temp": 63, "power": 137, "vram": 10891, "ram": 44000, "rss": 3748},
    "gpt-oss-20b-a4b-q4-64k-think-high": {"decode": 30.4, "prefill": 2034, "pre_ms": 18638, "dec_ms": 131579, "pre_mtok": 0.50, "dec_mtok": 32.89, "acc": "—", "place": "CPU", "cpu": 920, "gpu_util": 55, "temp": 63, "power": 137, "vram": 10891, "ram": 44000, "rss": 3748},
    "gpt-oss-20b-a4b-q4-128k-think-low": {"decode": 28.5, "prefill": 1948, "pre_ms": 19317, "dec_ms": 140351, "pre_mtok": 0.51, "dec_mtok": 35.09, "acc": "—", "place": "CPU", "cpu": 1061, "gpu_util": 55, "temp": 60, "power": 115, "vram": 10893, "ram": 44000, "rss": 3749},
    "gpt-oss-20b-a4b-q4-128k-think-medium": {"decode": 29.0, "prefill": 1971, "pre_ms": 19117, "dec_ms": 137931, "pre_mtok": 0.51, "dec_mtok": 34.48, "acc": "—", "place": "CPU", "cpu": 1026, "gpu_util": 55, "temp": 60, "power": 115, "vram": 10893, "ram": 44000, "rss": 3749},
    "gpt-oss-20b-a4b-q4-128k-think-high": {"decode": 29.3, "prefill": 1976, "pre_ms": 19043, "dec_ms": 136519, "pre_mtok": 0.51, "dec_mtok": 34.13, "acc": "—", "place": "CPU", "cpu": 719, "gpu_util": 55, "temp": 59, "power": 110, "vram": 10893, "ram": 44000, "rss": 3749},
    # qwen-3.5-9b MTP (old bench)
    "qwen-3.5-9b-q4-mtp-16k": {"decode": 70.4, "prefill": 1545, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.95, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.5-9b-q4-mtp-64k": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.5-9b-q4-mtp-128k": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.5-9b-q4-mtp-256k": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.5-9b-q4-mtp-16k-think": {"decode": 67.4, "prefill": 1545, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.84, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.5-9b-q4-mtp-64k-think": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.5-9b-q4-mtp-128k-think": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.5-9b-q4-mtp-256k-think": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    # qwen-3.6-35b MTP (old bench)
    "qwen-3.6-35b-a3b-q4-mtp-4k": {"decode": 49.4, "prefill": 1066, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.96, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-8k": {"decode": 44.6, "prefill": 1312, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.96, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-16k": {"decode": 48.7, "prefill": 1263, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.96, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-64k": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-128k": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-256k": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-4k-think": {"decode": 44.0, "prefill": 1073, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.94, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-8k-think": {"decode": 42.3, "prefill": 1311, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.94, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-16k-think": {"decode": 28.5, "prefill": 1258, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.94, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-64k-think": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-128k-think": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "qwen-3.6-35b-a3b-q4-mtp-256k-think": {"decode": "—", "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    # gemma-4 (old bench)
    "gemma-4-12b-q4-qat-mtp-16k": {"decode": 86.1, "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.79, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "gemma-4-12b-q4-qat-mtp-16k-think": {"decode": 76.7, "prefill": "—", "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "0.56–0.71", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "gemma-4-26b-a4b-q4-qat-mtp-4k": {"decode": 45.4, "prefill": 1392, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.96, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "gemma-4-26b-a4b-q4-qat-mtp-8k": {"decode": 47.0, "prefill": 1612, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.96, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "gemma-4-26b-a4b-q4-qat-mtp-16k": {"decode": 52.6, "prefill": 1766, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.96, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "gemma-4-26b-a4b-q4-qat-mtp-4k-think": {"decode": 63.4, "prefill": 1456, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.94, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "gemma-4-26b-a4b-q4-qat-mtp-8k-think": {"decode": 40.9, "prefill": 1568, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.94, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "gemma-4-26b-a4b-q4-qat-mtp-16k-think": {"decode": 43.9, "prefill": 1752, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.94, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    # lfm-2.5 (old bench)
    "lfm-2.5-8b-a1b-q4-4k-think": {"decode": 140.7, "prefill": 5382, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "lfm-2.5-8b-a1b-q4-8k-think": {"decode": 130.0, "prefill": 5835, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "lfm-2.5-8b-a1b-q4-16k-think": {"decode": 135.4, "prefill": 5622, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "lfm-2.5-8b-a1b-q4-32k-think": {"decode": 120.4, "prefill": 4374, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    # ornith (old bench)
    "ornith-1.5-9b-q4-mtp-64k-think": {"decode": 46, "prefill": 1523, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.89, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "ornith-1.5-9b-q4-mtp-64k-think-coder": {"decode": "—", "prefill": 1523, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.94, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "ornith-1.5-9b-q4-mtp-128k-think": {"decode": "—", "prefill": 1530, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.91, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "ornith-1.5-9b-q4-mtp-128k-think-coder": {"decode": "—", "prefill": 1530, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.95, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "ornith-1.5-9b-q4-mtp-256k-think": {"decode": "—", "prefill": 1523, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.93, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    "ornith-1.5-9b-q4-mtp-256k-think-coder": {"decode": "—", "prefill": 1523, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": 0.92, "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
    # zamai
    "zamai-llama3-pashto-q8-8k": {"decode": 34.0, "prefill": 2012, "pre_ms": "—", "dec_ms": "—", "pre_mtok": "—", "dec_mtok": "—", "acc": "—", "place": "unverified", "cpu": "—", "gpu_util": "—", "temp": "—", "power": "—", "vram": "—", "ram": "—", "rss": "—"},
}

# Parse models.ini to get ctx for each entry
def parse_ini():
    entries = {}
    current = None
    with open(INI_PATH) as f:
        for line in f:
            m = re.match(r'^\[(.+)\]$', line.strip())
            if m and m.group(1) != "*":
                current = m.group(1)
                entries[current] = {}
            elif current and 'ctx-size' in line:
                m2 = re.search(r'ctx-size\s*=\s*(\d+)', line)
                if m2:
                    entries[current]['ctx'] = int(m2.group(1))
            elif current and 'batch-size' in line:
                m2 = re.search(r'batch-size\s*=\s*(\d+)', line)
                if m2:
                    entries[current]['batch'] = int(m2.group(1))
            elif current and 'spec-draft-n-max' in line:
                m2 = re.search(r'spec-draft-n-max\s*=\s*(\d+)', line)
                if m2:
                    entries[current]['n_max'] = int(m2.group(1))
            elif current and 'spec-draft-p-min' in line:
                m2 = re.search(r'spec-draft-p-min\s*=\s*([\d.]+)', line)
                if m2:
                    entries[current]['p_min'] = float(m2.group(1))
            elif current and 'reasoning' in line:
                m2 = re.search(r'reasoning\s*=\s*(\w+)', line)
                if m2:
                    entries[current]['reasoning'] = m2.group(1)
    return entries

ini = parse_ini()
all_entries = sorted(ini.keys())

lines = []
lines.append("# Full Metrics Table")
lines.append("")
lines.append("All models.ini entries with complete benchmark data. RTX 3060 12GB.")
lines.append("")
lines.append("## Columns")
lines.append("")
lines.append("| Column | Description |")
lines.append("|---|---|")
lines.append("| model | Section header name from models.ini |")
lines.append("| ctx | Context window size |")
lines.append("| batch | batch-size |")
lines.append("| n_max | spec-draft-n-max (MTP models only) |")
lines.append("| p_min | spec-draft-p-min (MTP models only) |")
lines.append("| drafter | in-model / Q4_0 root / none |")
lines.append("| reasoning | off / on / low / medium / high |")
lines.append("| decode_t/s | Decode speed (tokens per second) |")
lines.append("| prefill_t/s | Prefill speed (tokens per second) |")
lines.append("| prefill_ms | Total prefill latency (ms) |")
lines.append("| decode_ms | Total decode latency (ms) |")
lines.append("| pre_tok_ms | Per-token prefill time (ms) |")
lines.append("| dec_tok_ms | Per-token decode time (ms) |")
lines.append("| acc | Draft acceptance rate |")
lines.append("| placement | GPU / CPU / AMBIGUOUS / unverified |")
lines.append("| cpu% | Average CPU% during decode |")
lines.append("| gpu% | Average GPU utilization% |")
lines.append("| temp_c | GPU temperature (C) |")
lines.append("| power_w | GPU power draw (W) |")
lines.append("| vram | VRAM used (MiB) |")
lines.append("| ram | System RAM used (MiB) |")
lines.append("| rss | Process RSS (MiB) |")
lines.append("")
lines.append("## Notes")
lines.append("")
lines.append("- Coder variants share benchmarks with non-coder equivalents (same model, same batch, different sampling params)")
lines.append("- `unverified` = bench-marked with old methodology (1000 tokens, 50s polling) — placement data unreliable")
lines.append("- GLM 4.7, REAP, gpt-oss: full metrics (4000 tokens, 160s polling)")
lines.append("- qwen, gemma, lfm, ornith, zamai: partial metrics only")
lines.append("- **Rows without explicit batch-size are UNTRUSTED** — benchmarked with default 4096 (wrong). Re-bench after batch bisect.")
lines.append("- Coder variants do NOT need benchmarking — copy non-coder values.")
lines.append("")
lines.append("## Benchmark Data")
lines.append("")
lines.append("| model | ctx | batch | n_max | p_min | drafter | reasoning | decode_t/s | prefill_t/s | prefill_ms | decode_ms | pre_tok_ms | dec_tok_ms | acc | placement | cpu% | gpu% | temp_c | power_w | vram | ram | rss |")
lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")

for name in all_entries:
    meta = ini[name]
    bench = BENCH_DATA.get(name, {})
    
    ctx = meta.get('ctx', '—')
    if isinstance(ctx, int):
        if ctx >= 1000:
            ctx = f"{ctx // 1024}k" if ctx % 1024 == 0 else str(ctx)
        else:
            ctx = str(ctx)
    
    row = [
        f"`{name}`",
        str(ctx),
        str(meta.get('batch', '—')),
        str(meta.get('n_max', '—')),
        str(meta.get('p_min', '—')),
        meta.get('drafter', '—'),
        meta.get('reasoning', '—'),
        str(bench.get('decode', '—')),
        str(bench.get('prefill', '—')),
        str(bench.get('pre_ms', '—')),
        str(bench.get('dec_ms', '—')),
        str(bench.get('pre_mtok', '—')),
        str(bench.get('dec_mtok', '—')),
        str(bench.get('acc', '—')),
        bench.get('place', '—'),
        str(bench.get('cpu', '—')),
        str(bench.get('gpu_util', '—')),
        str(bench.get('temp', '—')),
        str(bench.get('power', '—')),
        str(bench.get('vram', '—')),
        str(bench.get('ram', '—')),
        str(bench.get('rss', '—')),
    ]
    lines.append("| " + " | ".join(row) + " |")

with open(OUT_PATH, "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"Generated full-metrics.md with {len(all_entries)} entries")
