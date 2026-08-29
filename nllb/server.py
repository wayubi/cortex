"""NLLB translation service — any Hugging Face translation model, GPU only."""

import gc
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel
import torch
import uvicorn
from transformers import AutoTokenizer, AutoModelForSeq2SeqLM

app = FastAPI(title="NLLB Translation Service")

DEFAULT_MODEL = "facebook/nllb-200-3.3B"

cache: dict[str, tuple[AutoTokenizer, AutoModelForSeq2SeqLM]] = {}
DEFAULT_SRC = "eng_Latn"


class TranslateRequest(BaseModel):
    text: str
    model: str = DEFAULT_MODEL
    src_lang: str = DEFAULT_SRC
    tgt_lang: str
    max_length: int = 4096


def get_model(name: str):
    if name not in cache:
        if cache:
            print(f"Evicting cached model to load {name}")
            cache.clear()
            torch.cuda.empty_cache()
        print(f"Loading model: {name}")
        try:
            tok = AutoTokenizer.from_pretrained(name)
        except Exception:
            print(f"Tokenizer load failed for {name}, falling back to base NLLB tokenizer")
            tok = AutoTokenizer.from_pretrained(DEFAULT_MODEL)
        try:
            mdl = AutoModelForSeq2SeqLM.from_pretrained(
                name,
                torch_dtype=torch.float16,
                low_cpu_mem_usage=True,
            )
            mdl.cuda()
        except Exception:
            torch.cuda.empty_cache()
            raise
        cache[name] = (tok, mdl)
        print(f"Model loaded: {name}")
    return cache[name]


@app.post("/v1/translate")
def translate(req: TranslateRequest):
    tok, mdl = get_model(req.model)
    tok.src_lang = req.src_lang
    encoded = tok(req.text, return_tensors="pt").to(mdl.device)
    tgt_lang_id = tok.convert_tokens_to_ids(req.tgt_lang)
    result = mdl.generate(
        **encoded,
        forced_bos_token_id=tgt_lang_id,
        max_length=req.max_length,
    )
    translated = tok.batch_decode(result, skip_special_tokens=True)[0]
    return {"translated": translated}


@app.get("/v1/models")
def models():
    return {
        "data": [
            {"id": name, "status": {"value": "loaded"}}
            for name in cache
        ]
    }


@app.post("/v1/models/unload")
def unload(name: str = None):
    targets = [name] if name else list(cache.keys())
    for n in targets:
        if n in cache:
            _, mdl = cache[n]
            mdl.cpu()
            del cache[n]
    gc.collect()
    torch.cuda.empty_cache()
    if name:
        return {"status": "unloaded", "model": name}
    return {"status": "unloaded", "models": targets}


@app.get("/health")
def health():
    return {
        "status": "ok",
        "gpu": torch.cuda.is_available(),
        "gpu_name": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
        "loaded_models": list(cache.keys()),
    }


if __name__ == "__main__":
    assert torch.cuda.is_available(), "GPU required — no CPU fallback"
    print(f"GPU: {torch.cuda.get_device_name(0)}")
    uvicorn.run(app, host="0.0.0.0", port=5002)
