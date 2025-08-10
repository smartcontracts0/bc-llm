# ipfs_service.py
import os, json, io
import requests
from fastapi import FastAPI, UploadFile, File, Body, HTTPException
from fastapi.middleware.cors import CORSMiddleware

CONFIG_PATH = "ipfs_config.json"

app = FastAPI(title="IPFS Proxy", version="1.0.0")

# Allow your local static server origins
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://127.0.0.1:8000",
        "http://localhost:8000",
        "http://127.0.0.1:5500",
        "http://localhost:5500"
    ],
    allow_methods=["*"],
    allow_headers=["*"]
)

def load_config():
    if not os.path.exists(CONFIG_PATH):
        raise RuntimeError(f"{CONFIG_PATH} not found. Create it from ipfs_config.example.json")
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

@app.get("/health")
def health():
    return {"ok": True}

@app.get("/version")
def version():
    cfg = load_config()
    return {"service": app.version, "provider": cfg.get("provider")}

@app.post("/ipfs/pin_json")
def pin_json(payload: dict = Body(...)):
    cfg = load_config()
    provider = cfg.get("provider")

    if provider == "pinata":
        jwt = (cfg.get("pinata") or {}).get("jwt")
        if not jwt:
            raise HTTPException(status_code=500, detail="pinata.jwt missing in ipfs_config.json")
        r = requests.post(
            "https://api.pinata.cloud/pinning/pinJSONToIPFS",
            headers={"Authorization": f"Bearer {jwt}"},
            json=payload,
            timeout=60
        )
        if not r.ok:
            raise HTTPException(status_code=r.status_code, detail=r.text)
        cid = r.json().get("IpfsHash")

        gw = (cfg.get("pinata") or {}).get("gateway", "https://gateway.pinata.cloud/ipfs/")
        return {"cid": cid, "uri": f"ipfs://{cid}", "gateway_url": f"{gw.rstrip('/')}/{cid}"}

    elif provider == "web3storage":
        token = (cfg.get("web3storage") or {}).get("token")
        if not token:
            raise HTTPException(status_code=500, detail="web3storage.token missing in ipfs_config.json")
        # Upload JSON as a single file
        data = io.BytesIO(json.dumps(payload).encode("utf-8"))
        r = requests.post(
            "https://api.web3.storage/upload",
            headers={"Authorization": f"Bearer {token}"},
            data=data.getvalue(),
            timeout=120
        )
        if not r.ok:
            raise HTTPException(status_code=r.status_code, detail=r.text)
        cid = r.json().get("cid")
        gw = (cfg.get("web3storage") or {}).get("gateway", "https://w3s.link/ipfs/")
        return {"cid": cid, "uri": f"ipfs://{cid}", "gateway_url": f"{gw.rstrip('/')}/{cid}"}

    else:
        raise HTTPException(status_code=400, detail=f"Unsupported provider: {provider}")

@app.post("/ipfs/pin_file")
async def pin_file(file: UploadFile = File(...)):
    cfg = load_config()
    provider = cfg.get("provider")

    content = await file.read()
    filename = file.filename or "upload.bin"

    if provider == "pinata":
        jwt = (cfg.get("pinata") or {}).get("jwt")
        if not jwt:
            raise HTTPException(status_code=500, detail="pinata.jwt missing in ipfs_config.json")
        files = {
            "file": (filename, content, file.content_type or "application/octet-stream")
        }
        r = requests.post(
            "https://api.pinata.cloud/pinning/pinFileToIPFS",
            headers={"Authorization": f"Bearer {jwt}"},
            files=files,
            timeout=300
        )
        if not r.ok:
            raise HTTPException(status_code=r.status_code, detail=r.text)
        cid = r.json().get("IpfsHash")
        gw = (cfg.get("pinata") or {}).get("gateway", "https://gateway.pinata.cloud/ipfs/")
        return {"cid": cid, "uri": f"ipfs://{cid}", "gateway_url": f"{gw.rstrip('/')}/{cid}"}

    elif provider == "web3storage":
        token = (cfg.get("web3storage") or {}).get("token")
        if not token:
            raise HTTPException(status_code=500, detail="web3storage.token missing in ipfs_config.json")
        # Web3.Storage expects raw file bytes (or a CAR). We'll send file bytes.
        r = requests.post(
            "https://api.web3.storage/upload",
            headers={"Authorization": f"Bearer {token}"},
            data=content,
            timeout=300
        )
        if not r.ok:
            raise HTTPException(status_code=r.status_code, detail=r.text)
        cid = r.json().get("cid")
        gw = (cfg.get("web3storage") or {}).get("gateway", "https://w3s.link/ipfs/")
        return {"cid": cid, "uri": f"ipfs://{cid}", "gateway_url": f"{gw.rstrip('/')}/{cid}"}

    else:
        raise HTTPException(status_code=400, detail=f"Unsupported provider: {provider}")
