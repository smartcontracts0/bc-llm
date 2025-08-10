# tokenizer_service.py
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Optional, Tuple
import os, hashlib

import transformers, tokenizers
from transformers import AutoTokenizer

DEFAULT_REPO = "Qwen/Qwen2.5-3B-Instruct"
LOCAL_DIR = os.environ.get("LOCAL_TOKENIZER_DIR", "assets/qwen-tokenizer")
LOCAL_ONLY = os.environ.get("LOCAL_ONLY", "0") == "1"

app = FastAPI(title="Tokenizer Service", version="1.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:8000", "http://localhost:8000", "*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# cache
_tokenizer = None
_tok_src: Optional[str] = None
_tok_local_only: bool = False
_tok_md5: Optional[str] = None  # backend_tokenizer.to_str() md5 fingerprint


def _file_md5(path: str) -> Optional[str]:
    try:
        with open(path, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()
    except Exception:
        return None


def _backend_md5(tok) -> str:
    # identical to Colab fingerprinting method
    bk = tok.backend_tokenizer.to_str()
    return hashlib.md5(bk.encode("utf-8")).hexdigest()


def _load_tokenizer(source: str, local_only: bool):
    kwargs = {}
    if local_only:
        kwargs["local_files_only"] = True
    # Ensure identical libs to Colab
    tok = AutoTokenizer.from_pretrained(source, **kwargs)
    return tok


def get_tokenizer(repo: Optional[str] = None) -> Tuple[AutoTokenizer, str, bool, str]:
    """
    Returns (tokenizer, source, local_only, backend_md5)
    Preference order:
      1) LOCAL_DIR if it has tokenizer.json (when exists)
      2) explicit repo param, else DEFAULT_REPO
    """
    global _tokenizer, _tok_src, _tok_local_only, _tok_md5

    # choose source
    local_tok_json = os.path.join(LOCAL_DIR, "tokenizer.json")
    if os.path.exists(local_tok_json):
        source = LOCAL_DIR
        local_only = True if LOCAL_ONLY or os.path.isdir(LOCAL_DIR) else False
    else:
        source = repo or DEFAULT_REPO
        local_only = LOCAL_ONLY  # only if you force it

    needs_load = (
        _tokenizer is None
        or _tok_src != source
        or _tok_local_only != local_only
    )

    if needs_load:
        try:
            tok = _load_tokenizer(source, local_only)
        except Exception as e:
            # If local-only failed and we have a repo, try remote (unless hard-forced LOCAL_ONLY)
            if (source == LOCAL_DIR or local_only) and not LOCAL_ONLY and repo:
                tok = _load_tokenizer(repo, local_only=False)
                source = repo
                local_only = False
            else:
                raise HTTPException(status_code=500, detail=f"Failed to load tokenizer from '{source}': {e}")

        _tokenizer = tok
        _tok_src = source
        _tok_local_only = local_only
        _tok_md5 = _backend_md5(tok)

    return _tokenizer, _tok_src, _tok_local_only, _tok_md5


class TokenizeBulkIn(BaseModel):
    prompts: List[str]
    responses: List[str]
    truncation: bool = True
    max_length: int = 512
    repo: Optional[str] = None  # optional override


class TokenizeBulkOut(BaseModel):
    input_ids: List[List[int]]
    attention_mask: List[List[int]]


@app.get("/health")
def health():
    return {"ok": True}


# keep /info for the viewer, and /version for manual checks
@app.get("/info")
@app.get("/version")
def info(repo: Optional[str] = None):
    tok, src, local_only, md5 = get_tokenizer(repo)
    return {
        "service": app.version,
        "transformers": transformers.__version__,
        "tokenizers": tokenizers.__version__,
        "source": src,
        "local_only": local_only,
        "backend_tokenizer_md5": md5,
        "padding_side": tok.padding_side,
        "truncation_side": tok.truncation_side,
        "local_tokenizer_json_md5": _file_md5(os.path.join(LOCAL_DIR, "tokenizer.json")) if os.path.isdir(LOCAL_DIR) else None,
    }


@app.post("/tokenize_bulk", response_model=TokenizeBulkOut)
def tokenize_bulk(body: TokenizeBulkIn):
    if len(body.prompts) != len(body.responses):
        raise HTTPException(status_code=400, detail="prompts and responses must have the same length")

    tok, _, _, _ = get_tokenizer(body.repo)

    try:
        enc = tok(
            body.prompts,
            body.responses,  # EXACTLY as in Colab: second arg as text_pair
            truncation=body.truncation,
            max_length=body.max_length,
            add_special_tokens=True,
            return_attention_mask=True,
            padding=False,
            return_tensors=None,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"tokenization failed: {e}")

    def to_py(x):
        # ensure plain python lists (no numpy/torch)
        if hasattr(x, "tolist"):
            return x.tolist()
        return list(x)

    input_ids = [list(map(int, seq)) for seq in to_py(enc["input_ids"])]
    attention_mask = [list(map(int, seq)) for seq in to_py(enc["attention_mask"])]

    return TokenizeBulkOut(input_ids=input_ids, attention_mask=attention_mask)


if __name__ == "__main__":
    # convenience: python tokenizer_service.py
    import uvicorn
    uvicorn.run("tokenizer_service:app", host="127.0.0.1", port=8010, reload=False)
