# Full Metrics Table

All 76 models.ini entries with complete benchmark data. RTX 3060 12GB.

Columns: model | ctx | batch | n_max | p_min | drafter | reasoning | decode_t/s | prefill_t/s | prefill_total_ms | decode_total_ms | prefill_ms_tok | decode_ms_tok | acceptance | placement | avg_cpu_pct | avg_gpu_util_pct | gpu_temp_c | gpu_power_w | vram_mib | ram_mib | rss_mib

Coder variants share benchmarks with non-coder equivalents.

| model | ctx | batch | n_max | p_min | drafter | reasoning | decode_t/s | prefill_t/s | prefill_ms | decode_ms | pre_tok_ms | dec_tok_ms | acc | placement | cpu% | gpu% | temp_c | power_w | vram | ram | rss |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `glm-4.7-30b-a3b-flash-q4-64k` | 64k | 4096 | — | — | none | off | 24.6 | 510 | 61436 | 162690 | 1.96 | 40.68 | — | CPU | 739 | 68 | 60 | 120 | 10993 | 49000 | 9320 |
| `glm-4.7-30b-a3b-flash-q4-64k-coder` | — | 4096 | — | — | none | off | 24.6 | 510 | 61436 | 162690 | 1.96 | 40.68 | — | CPU | 739 | 68 | 60 | 120 | 10993 | 49000 | 9320 |
| `glm-4.7-30b-a3b-flash-q4-64k-think` | — | 4096 | — | — | none | on | 22.9 | 511 | 61215 | 174687 | 1.96 | 43.68 | — | CPU | 1014 | 68 | 60 | 117 | 10993 | 49000 | 9458 |
| `glm-4.7-30b-a3b-flash-q4-64k-think-coder` | — | 4096 | — | — | none | on | 22.9 | 511 | 61215 | 174687 | 1.96 | 43.68 | — | CPU | 1014 | 68 | 60 | 117 | 10993 | 49000 | 9458 |
| `glm-4.7-30b-a3b-flash-q4-128k` | 128k | 4096 | — | — | none | off | 22.4 | 504 | 62164 | 178721 | 1.99 | 44.69 | — | CPU | 1027 | 69 | 59 | 115 | 10911 | 51000 | 11592 |
| `glm-4.7-30b-a3b-flash-q4-128k-coder` | — | 4096 | — | — | none | off | 22.4 | 504 | 62164 | 178721 | 1.99 | 44.69 | — | CPU | 1027 | 69 | 59 | 115 | 10911 | 51000 | 11592 |
| `glm-4.7-30b-a3b-flash-q4-128k-think` | — | 4096 | — | — | none | on | 22.4 | 504 | 62090 | 178203 | 1.98 | 44.56 | — | CPU | 1128 | 68 | 59 | 114 | 10911 | 51000 | 11592 |
| `glm-4.7-30b-a3b-flash-q4-128k-think-coder` | — | 4096 | — | — | none | on | 22.4 | 504 | 62090 | 178203 | 1.98 | 44.56 | — | CPU | 1128 | 68 | 59 | 114 | 10911 | 51000 | 11592 |
| `glm-4.7-30b-a3b-flash-q4-198k` | 198k | 4096 | — | — | none | off | 17.6 | 499 | 62725 | 226627 | 2.0 | 56.67 | — | CPU | 1060 | 61 | 57 | 105 | 10975 | 53000 | 13776 |
| `glm-4.7-30b-a3b-flash-q4-198k-coder` | — | 4096 | — | — | none | off | 17.6 | 499 | 62725 | 226627 | 2.0 | 56.67 | — | CPU | 1060 | 61 | 57 | 105 | 10975 | 53000 | 13776 |
| `glm-4.7-30b-a3b-flash-q4-198k-think` | — | 4096 | — | — | none | on | 19.8 | 499 | 62783 | 202174 | 2.01 | 50.56 | — | CPU | 1124 | 65 | 57 | 106 | 10975 | 54000 | 13773 |
| `glm-4.7-30b-a3b-flash-q4-198k-think-coder` | — | 4096 | — | — | none | on | 19.8 | 499 | 62783 | 202174 | 2.01 | 50.56 | — | CPU | 1124 | 65 | 57 | 106 | 10975 | 54000 | 13773 |
| `glm-4.7-23b-a3b-flash-reap-q4-64k` | 64k | 4096 | — | — | none | off | 25.0 | 525 | 59603 | 159864 | 1.9 | 39.98 | — | CPU | 715 | 70 | 62 | 125 | 10927 | 45000 | 6404 |
| `glm-4.7-23b-a3b-flash-reap-q4-64k-coder` | — | 4096 | — | — | none | off | 25.0 | 525 | 59603 | 159864 | 1.9 | 39.98 | — | CPU | 715 | 70 | 62 | 125 | 10927 | 45000 | 6404 |
| `glm-4.7-23b-a3b-flash-reap-q4-64k-think` | — | 4096 | — | — | none | on | 23.7 | 523 | 59847 | 169006 | 1.91 | 42.26 | — | CPU | 911 | 72 | 60 | 124 | 10927 | 46000 | 6405 |
| `glm-4.7-23b-a3b-flash-reap-q4-64k-think-coder` | — | 4096 | — | — | none | on | 23.7 | 523 | 59847 | 169006 | 1.91 | 42.26 | — | CPU | 911 | 72 | 60 | 124 | 10927 | 46000 | 6405 |
| `glm-4.7-23b-a3b-flash-reap-q4-128k` | 128k | 4096 | — | — | none | off | 22.7 | 517 | 60552 | 176016 | 1.93 | 44.01 | — | CPU | 1049 | 67 | 60 | 118 | 10935 | 47000 | 8448 |
| `glm-4.7-23b-a3b-flash-reap-q4-128k-coder` | — | 4096 | — | — | none | off | 22.7 | 517 | 60552 | 176016 | 1.93 | 44.01 | — | CPU | 1049 | 67 | 60 | 118 | 10935 | 47000 | 8448 |
| `glm-4.7-23b-a3b-flash-reap-q4-128k-think` | — | 4096 | — | — | none | on | 23.3 | 517 | 60542 | 171370 | 1.93 | 42.85 | — | CPU | 1046 | 70 | 60 | 119 | 10935 | 48000 | 8448 |
| `glm-4.7-23b-a3b-flash-reap-q4-128k-think-coder` | — | 4096 | — | — | none | on | 23.3 | 517 | 60542 | 171370 | 1.93 | 42.85 | — | CPU | 1046 | 70 | 60 | 119 | 10935 | 48000 | 8448 |
| `glm-4.7-23b-a3b-flash-reap-q4-198k` | 198k | 4096 | — | — | none | off | 19.7 | 510 | 61444 | 203101 | 1.96 | 50.79 | — | CPU | 1150 | 62 | 57 | 108 | 10925 | 50000 | 10704 |
| `glm-4.7-23b-a3b-flash-reap-q4-198k-coder` | — | 4096 | — | — | none | off | 19.7 | 510 | 61444 | 203101 | 1.96 | 50.79 | — | CPU | 1150 | 62 | 57 | 108 | 10925 | 50000 | 10704 |
| `glm-4.7-23b-a3b-flash-reap-q4-198k-think` | — | 4096 | — | — | none | on | 18.1 | 509 | 61530 | 221301 | 1.97 | 55.34 | — | CPU | 1133 | 58 | 56 | 103 | 10925 | 50000 | 10704 |
| `glm-4.7-23b-a3b-flash-reap-q4-198k-think-coder` | — | 4096 | — | — | none | on | 18.1 | 509 | 61530 | 221301 | 1.97 | 55.34 | — | CPU | 1133 | 58 | 56 | 103 | 10925 | 50000 | 10704 |
| `gpt-oss-20b-a4b-q4-low-64k` | 64k | 4096 | — | — | none | low | 30.9 | 2018 | 18719 | 129417 | 0.5 | 32.36 | — | CPU | 911 | 55 | 63 | 137 | 10891 | 44000 | 3748 |
| `gpt-oss-20b-a4b-q4-low-128k` | 128k | 4096 | — | — | none | low | 28.5 | 1948 | 19317 | 140351 | 0.51 | 35.09 | — | CPU | 1061 | 55 | 60 | 115 | 10893 | 44000 | 3749 |
| `gpt-oss-20b-a4b-q4-mid-64k` | 64k | 4096 | — | — | none | medium | 29.9 | 2001 | 18835 | 133779 | 0.5 | 33.44 | — | CPU | 941 | 55 | 63 | 137 | 10891 | 44000 | 3748 |
| `gpt-oss-20b-a4b-q4-mid-128k` | 128k | 4096 | — | — | none | medium | 29.0 | 1971 | 19117 | 137931 | 0.51 | 34.48 | — | CPU | 1026 | 55 | 60 | 115 | 10893 | 44000 | 3749 |
| `gpt-oss-20b-a4b-q4-high-64k` | 64k | 4096 | — | — | none | high | 30.4 | 2034 | 18638 | 131579 | 0.5 | 32.89 | — | CPU | 920 | 55 | 63 | 137 | 10891 | 44000 | 3748 |
| `gpt-oss-20b-a4b-q4-high-128k` | 128k | 4096 | — | — | none | high | 29.3 | 1976 | 19043 | 136519 | 0.51 | 34.13 | — | CPU | 719 | 55 | 59 | 110 | 10893 | 44000 | 3749 |
| `qwen-3.5-9b-q4-64k-uncensored` | — | 4544 | — | — | none | off | — | — | — | — | — | — | — | — | — | — | — | — | — | — | — |
| `qwen-3.5-9b-q4-64k-think-uncensored` | — | 4544 | — | — | none | on | — | — | — | — | — | — | — | — | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-64k-think-uncensored` | — | — | — | — | none | on | — | — | — | — | — | — | — | — | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-128k-think-uncensored` | — | 2688 | — | — | none | on | — | — | — | — | — | — | — | — | — | — | — | — | — | — | — |
| `qwen-3.5-9b-q4-mtp-16k` | 16k | 2048 | 2 | 0.7 | in-model | off | 70.4 | 1545 | — | — | — | — | 0.95 | unverified | — | — | — | — | — | — | — |
| `qwen-3.5-9b-q4-mtp-64k` | 64k | 1664 | 2 | 0.7 | in-model | off | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.5-9b-q4-mtp-128k` | 128k | 1344 | 2 | 0.7 | in-model | off | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.5-9b-q4-mtp-256k` | 256k | 448 | 2 | 0.7 | in-model | off | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.5-9b-q4-mtp-16k-think` | — | 2048 | 2 | 0.5 | in-model | on | 67.4 | 1545 | — | — | — | — | 0.84 | unverified | — | — | — | — | — | — | — |
| `qwen-3.5-9b-q4-mtp-64k-think` | — | 1664 | 2 | 0.7 | in-model | on | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.5-9b-q4-mtp-128k-think` | — | 1344 | 2 | 0.7 | in-model | on | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.5-9b-q4-mtp-256k-think` | — | 448 | 2 | 0.7 | in-model | on | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-4k` | 4k | 4096 | 2 | 0.7 | in-model | off | 49.4 | 1066 | — | — | — | — | 0.96 | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-4k-think` | — | 4096 | 2 | 0.7 | in-model | on | 44.0 | 1073 | — | — | — | — | 0.94 | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-8k` | 8k | 8192 | 2 | 0.7 | in-model | off | 44.6 | 1312 | — | — | — | — | 0.96 | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-8k-think` | — | 8192 | 2 | 0.7 | in-model | on | 42.3 | 1311 | — | — | — | — | 0.94 | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-16k` | 16k | 3584 | 2 | 0.7 | in-model | off | 48.7 | 1263 | — | — | — | — | 0.96 | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-16k-think` | — | 3584 | 2 | 0.7 | in-model | on | 28.5 | 1258 | — | — | — | — | 0.94 | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-64k` | 64k | 448 | 2 | 0.7 | in-model | off | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-64k-think` | — | 448 | 2 | 0.7 | in-model | on | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-128k` | 128k | — | 2 | 0.7 | in-model | off | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-128k-think` | — | 2688 | 2 | 0.7 | in-model | on | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-256k` | 256k | — | 2 | 0.7 | in-model | off | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `qwen-3.6-35b-a3b-q4-mtp-256k-think` | — | 1920 | 2 | 0.7 | in-model | on | — | — | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `gemma-4-12b-q4-qat-mtp-16k` | 16k | 8640 | 5 | 0.7 | Q4_0 root | off | 86.1 | — | — | — | — | — | 0.79 | unverified | — | — | — | — | — | — | — |
| `gemma-4-12b-q4-qat-mtp-16k-think` | — | 8576 | 5 | 0.5 | Q4_0 root | on | 76.7 | — | — | — | — | — | 0.56–0.71 | unverified | — | — | — | — | — | — | — |
| `gemma-4-26b-a4b-q4-qat-mtp-4k` | 4k | 4096 | 4 | 0.7 | Q4_0 root | off | 45.4 | 1392 | — | — | — | — | 0.96 | unverified | — | — | — | — | — | — | — |
| `gemma-4-26b-a4b-q4-qat-mtp-4k-think` | — | 4096 | 4 | 0.7 | Q4_0 root | on | 63.4 | 1456 | — | — | — | — | 0.94 | unverified | — | — | — | — | — | — | — |
| `gemma-4-26b-a4b-q4-qat-mtp-8k` | 8k | 4096 | 4 | 0.7 | Q4_0 root | off | 47.0 | 1612 | — | — | — | — | 0.96 | unverified | — | — | — | — | — | — | — |
| `gemma-4-26b-a4b-q4-qat-mtp-8k-think` | — | 4096 | 4 | 0.7 | Q4_0 root | on | 40.9 | 1568 | — | — | — | — | 0.94 | unverified | — | — | — | — | — | — | — |
| `gemma-4-26b-a4b-q4-qat-mtp-16k` | 16k | 4096 | 4 | 0.7 | Q4_0 root | off | 52.6 | 1766 | — | — | — | — | 0.96 | unverified | — | — | — | — | — | — | — |
| `gemma-4-26b-a4b-q4-qat-mtp-16k-think` | — | 4096 | 4 | 0.7 | Q4_0 root | on | 43.9 | 1752 | — | — | — | — | 0.94 | unverified | — | — | — | — | — | — | — |
| `lfm-2.5-8b-a1b-q4-4k-think` | — | 16384 | — | — | none | on | 140.7 | 5382 | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `lfm-2.5-8b-a1b-q4-8k-think` | — | 16384 | — | — | none | on | 130.0 | 5835 | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `lfm-2.5-8b-a1b-q4-16k-think` | — | 16384 | — | — | none | on | 135.4 | 5622 | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `lfm-2.5-8b-a1b-q4-32k-think` | — | 16384 | — | — | none | on | 120.4 | 4374 | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `zamai-llama3-pashto-q8-8k` | 8k | 8192 | — | — | none | — | 34.0 | 2012 | — | — | — | — | — | unverified | — | — | — | — | — | — | — |
| `ornith-1.5-9b-q4-mtp-64k-think` | — | 8192 | 3 | 0.7 | in-model | on | 46 | 1523 | — | — | — | — | 0.89 | unverified | — | — | — | — | — | — | — |
| `ornith-1.5-9b-q4-mtp-64k-think-coder` | — | 8192 | 3 | 0.7 | in-model | on | — | 1523 | — | — | — | — | 0.94 | unverified | — | — | — | — | — | — | — |
| `ornith-1.5-9b-q4-mtp-128k-think` | — | 4736 | 2 | 0.7 | in-model | on | — | 1530 | — | — | — | — | 0.91 | unverified | — | — | — | — | — | — | — |
| `ornith-1.5-9b-q4-mtp-128k-think-coder` | — | 4736 | 2 | 0.7 | in-model | on | — | 1530 | — | — | — | — | 0.95 | unverified | — | — | — | — | — | — | — |
| `ornith-1.5-9b-q4-mtp-256k-think` | — | 960 | 2 | 0.7 | in-model | on | — | 1523 | — | — | — | — | 0.93 | unverified | — | — | — | — | — | — | — |
| `ornith-1.5-9b-q4-mtp-256k-think-coder` | — | 960 | 2 | 0.7 | in-model | on | — | 1523 | — | — | — | — | 0.92 | unverified | — | — | — | — | — | — | — |
