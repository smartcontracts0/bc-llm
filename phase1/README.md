# Merkle-Backed Dataset Registry — **Phase 1**

A minimal prototype that proves dataset integrity on-chain.  
You (a) preprocess & tokenize a public demo dataset, (b) hash JSONL files and build a Merkle tree, (c) upload human‑readable metadata to IPFS, (d) register the dataset root on Sepolia via MetaMask, and (e) verify a target file’s inclusion with a Merkle proof.

---

## What’s in Phase 1

- **Static dapp** (no backend) with two pages:
  - `viewer.html` – read-only explorer for `DatasetRegistered` & `ModelRegistered` events, compare roots, and run `verifyFileHash` (can auto-fill from a local bundle).
  - `register.html` – MetaMask page to upload `preprocessing_metadata.json` to IPFS and call `registerDataset(datasetId, merkleRoot, metadataCID)`.
- **Local IPFS proxy** (`ipfs_service.py`) – tiny FastAPI service that forwards uploads to Pinata or Web3.Storage (so you don’t expose keys in the frontend).
- **Colab / scripts** – generate tokenized JSONL, compute Keccak leaf hashes, Merkle root + proofs, and produce two local artifacts:
  - `preprocessing_metadata.json` – human‑readable metadata (uploaded to IPFS by the dapp).
  - `verify_bundle.json` – `{ datasetId, version, leafHash, proof, merkleRoot, targetFile }` (loaded by the viewer to auto-fill verify fields).

> 👀 **Scope:** No model registrations yet (that’s Phase 2/3). Viewer can display `ModelRegistered` if present, but Phase 1 focuses on datasets.

---

## Folder layout (suggested)

```
phase-01/
  dapp/
    index.html          # simple navigator
    viewer.html         # explorer + verify
    register.html       # MetaMask + IPFS upload + registerDataset
  ipfs/
    ipfs_service.py
    ipfs_config.example.json
    (create your) ipfs_config.json   # NOT committed; contains your keys/token
  colab/
    ... your notebook or python script that writes:
      preprocessing_metadata.json
      verify_bundle.json
      tokenized_data/*.jsonl
```

You can rename/move, but keep:
- Dapp files together (so the relative links in `index.html` work).
- IPFS proxy config next to `ipfs_service.py`.

---

## Prereqs

- **Python 3.10+**
- `pip install fastapi uvicorn requests`
- **MetaMask** in your browser (connected to **Sepolia**).
- A funded Sepolia account (for `registerDataset` gas).
- An IPFS provider account:
  - **Pinata** (JWT) or **Web3.Storage** (token).

---

## Configure the IPFS proxy

Copy the example and fill in your real credentials:

```bash
cd phase-01/ipfs
cp ipfs_config.example.json ipfs_config.json
# edit ipfs_config.json with your token/JWT + gateway prefix
```

Start the proxy (allows CORS from your local static server):

```bash
uvicorn ipfs_service:app --host 127.0.0.1 --port 8020 --reload
```

Sanity checks:

- `GET http://127.0.0.1:8020/health` → `{"ok": true}`
- `GET http://127.0.0.1:8020/version` → shows provider info

---

## Run the dapp

From `phase-01/dapp`:

```bash
python -m http.server 8000
```

Open:
- **http://127.0.0.1:8000/index.html** (navigator)
- Or directly: `/register.html` and `/viewer.html`

> If you serve from a different port, update the “IPFS proxy URL” field in `register.html` (or just type it in the input before uploading).

---

## End‑to‑end workflow (Phase 1)

1. **Produce artifacts (Colab or local script)**
   - Canonicalize CSVs, tokenize into JSONL, hash each file with **Keccak‑256**, and build a Merkle tree where parents are `keccak(left || right)` and the last node is duplicated on odd levels.
   - Write:
     - `preprocessing_metadata.json`
     - `verify_bundle.json` (shape below)
2. **Upload metadata to IPFS (register.html)**
   - Connect MetaMask.
   - Choose `preprocessing_metadata.json` and click **Upload to IPFS** → **CID** auto-fills.
3. **Register dataset on Sepolia**
   - Enter dataset name (or paste) → click **Compute datasetId** (or precompute off‑chain; both are Keccak‑256 of the UTF‑8 string).
   - Paste **Merkle root** (from your Colab output).
   - Click **registerDataset** and confirm in MetaMask.
4. **Verify a file (viewer.html)**
   - Enter your **datasetId** and **block range**, then **Fetch DatasetRegistered**.
   - **Load bundle** → choose `verify_bundle.json` → fields auto‑fill (datasetId, version, leafHash, proof).
   - Click **Verify** → returns ✅ or ❌.

### `verify_bundle.json` (example)
```json
{
  "datasetId": "0x…",
  "version": 1,
  "leafHash": "0x…",
  "proof": ["0x…", "0x…"],
  "merkleRoot": "0x…",
  "targetFile": "tokenized_admissions.jsonl",
  "timestamp": "2025-08-10T16:59:41Z"
}
```

> The viewer also accepts earlier shapes, e.g. `dataset_id`, `leaf`, `root`, etc.

---

## Contract & network

- **Network:** Sepolia
- **Contract (example used in the UI):** `0x877291c5FdbFa77f2961971dE560eAb1B25E3A36`  
  Functions used in Phase 1:
  - `computeDatasetId(string name) → bytes32`
  - `registerDataset(bytes32 datasetId, bytes32 merkleRoot, string metadataCID)`
  - `getDatasetVersions(bytes32 datasetId) → DatasetVersion[]`
  - `verifyFileHash(bytes32 datasetId, uint256 version, bytes32 leafHash, bytes32[] proof) → bool`

> If you deploy a new address, change it in the inputs at the top of the pages (no rebuild needed).

---

## Common pitfalls

- **“Failed to fetch” on upload:** IPFS proxy not running, wrong port, or CORS. Check `ipfs_service.py` is on **8020** and your browser console/network tab.
- **“Not included / bad proof”:** Mismatch between Merkle construction on-chain vs off‑chain. Phase 1 uses:
  - leaf = `keccak(file_bytes)`
  - parent = `keccak(left || right)` (byte concat of two 32‑byte values)
  - duplicate the last node on odd levels
  - proof is **sibling order** as constructed above (no sorting by value).
- **Nothing shows in table:** Wrong block range or datasetId. Use `latest` or a wide range to start (e.g. `0-99999999`).

---

## Git hygiene

- Do **not** commit `ipfs/ipfs_config.json` (contains secrets).
- Suggested `.gitignore` entries:
  - `ipfs/ipfs_config.json`
  - `*.env`
  - `__pycache__/`, `.DS_Store`
  - `tokenized_data/`, `*.zip`, `*.car`
  - `.vscode/`

---

## License / citation

This code is for research prototyping. Cite as:  
*Merkle‑Backed Dataset Registry Prototype — Phase 1 (2025)*.

