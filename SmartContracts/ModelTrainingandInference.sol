// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title ModelTrainingAndInference - Phase 2 contract for model/run provenance & XAI logging
/// @notice Adds batch inference commitments (Merkle root) to cut cost O(N) → O(1).
///         Keeps single-inference logging for small demos. Large blobs live on IPFS.

interface IDatasetRegistry {
    function datasets(bytes32 datasetId, uint256 index)
        external
        view
        returns (
            bytes32 merkleRoot,
            string memory metadataCID,
            uint256 timestamp,
            address registrant,
            uint256 version
        );

    function getDatasetVersion(bytes32 datasetId, uint256 version)
        external
        view
        returns (
            bytes32 merkleRoot,
            string memory metadataCID,
            uint256 timestamp,
            address registrant,
            uint256 versionNum
        );
        

    function computeDatasetId(string calldata name) external pure returns (bytes32);

    function registerModel(
        bytes32 modelId,
        bytes32 datasetId,
        uint256 datasetVersion,
        bytes32 trainingConfigHash
    ) external;

    // NEW: operator path lets Phase-2 anchor on behalf of the EOA owner
    function registerModelOperator(
        bytes32 modelId,
        bytes32 datasetId,
        uint256 datasetVersion,
        bytes32 trainingConfigHash,
        address ownerEOA
    ) external;

}

contract ModelTrainingAndInference {
    /*──────────────────────── Admin / Pause ────────────────────────*/
    address public owner;
    bool    public paused;

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier whenNotPaused() { require(!paused, "paused"); _; }

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    function pause() external onlyOwner { paused = true; emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }

    /*────────────────────────── State ──────────────────────────────*/
    IDatasetRegistry public immutable registry;
    constructor(address registry_) {
        require(registry_ != address(0), "registry zero");
        registry = IDatasetRegistry(registry_);
        owner = msg.sender;
    }

    uint256 private _nonce;

    struct Model {
        address owner;
        bytes32 datasetId;
        uint256 datasetVersion;   // 1-based
        bytes32 datasetRoot;      // cached snapshot from Phase-1
        bytes32 codeHash;         // optional
        bytes32 archHash;         // optional
        string  modelURI;         // IPFS/model card/docs
        uint64  createdAt;
    }

    mapping(bytes32 => Model) public models;      // modelId => Model
    mapping(bytes32 => bool)   public modelExists;

    struct Run {
        bytes32 modelId;
        bytes32 configHash;
        uint64  startedAt;
        bool    finalized;
        bytes32 weightsHash;
        bytes32 metricsHash;
        string  artifactsCID;
        uint64  finalizedAt;
    }

    uint256 private _nextRunId = 1;
    mapping(uint256 => Run) public runs;          // runId => Run

    /*────────────────────────── Events ─────────────────────────────*/
    event ModelCreated(
        bytes32 indexed modelId,
        address indexed owner,
        bytes32 indexed datasetId,
        uint256 datasetVersion,
        bytes32 datasetRoot,
        bytes32 codeHash,
        bytes32 archHash,
        string  modelURI
    );

    event TrainingStarted(
        uint256 indexed runId,
        bytes32 indexed modelId,
        bytes32 configHash
    );

    event TrainingFinalized(
        uint256 indexed runId,
        bytes32 indexed modelId,
        bytes32 weightsHash,
        bytes32 metricsHash,
        string  artifactsCID
    );

    /// Single inference (fine for demos; expensive at scale)
    event InferenceLogged(
        bytes32 indexed modelId,
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 xaiHash,
        string  xaiCID
    );

    /// NEW: Batch commitment (Merkle root of per-inference leaves)
    /// - leaf := keccak256(abi.encodePacked(inputHash, outputHash, xaiHash))
    /// - internal nodes use the SAME sorted-pair rule as Phase-1:
    ///     if (a < b) keccak256(a||b) else keccak256(b||a)
    /// - `batchCID` points to an IPFS JSON bundle with the rows (+ optional salts)
    event InferenceBatchCommitted(
        bytes32 indexed modelId,
        bytes32 indexed batchRoot,
        uint256 count,
        string  batchCID
    );

    event RegistryAnchorAttempt(bytes32 indexed modelId, bool ok);

    /*──────────────────── Registration & Runs ──────────────────────*/
    function createModel(
        bytes32 modelId,
        bytes32 datasetId,
        uint256 datasetVersion,
        bytes32 codeHash,
        bytes32 archHash,
        string calldata modelURI,
        bytes32 initialConfigHash,
        bool    alsoAnchor
    ) public whenNotPaused returns (bytes32 newModelId) {
        bytes32 root = _fetchDatasetRoot(datasetId, datasetVersion);
        require(root != bytes32(0), "unknown dataset/version");

        newModelId = (modelId != bytes32(0))
            ? modelId
            : keccak256(abi.encodePacked(msg.sender, datasetId, datasetVersion, block.chainid, block.timestamp, _nonce++));

        require(!modelExists[newModelId], "modelId exists");

        models[newModelId] = Model({
            owner: msg.sender,
            datasetId: datasetId,
            datasetVersion: datasetVersion,
            datasetRoot: root,
            codeHash: codeHash,
            archHash: archHash,
            modelURI: modelURI,
            createdAt: uint64(block.timestamp)
        });
        modelExists[newModelId] = true;

        emit ModelCreated(newModelId, msg.sender, datasetId, datasetVersion, root, codeHash, archHash, modelURI);

        if (alsoAnchor) {
            bool ok = _tryAnchorInRegistry(newModelId, datasetId, datasetVersion, initialConfigHash);
            emit RegistryAnchorAttempt(newModelId, ok);
        }
    }

    function createModelByName(
        bytes32 modelId,
        string calldata datasetName,
        uint256 datasetVersion,
        bytes32 codeHash,
        bytes32 archHash,
        string calldata modelURI,
        bytes32 initialConfigHash,
        bool    alsoAnchor
    ) external whenNotPaused returns (bytes32) {
        bytes32 dsId = registry.computeDatasetId(datasetName);
        return createModel(modelId, dsId, datasetVersion, codeHash, archHash, modelURI, initialConfigHash, alsoAnchor);
    }

    modifier onlyModelOwner(bytes32 modelId) {
        require(modelExists[modelId], "model DNE");
        require(models[modelId].owner == msg.sender, "not model owner");
        _;
    }

    function startTrainingRun(bytes32 modelId, bytes32 configHash)
        external
        whenNotPaused
        onlyModelOwner(modelId)
        returns (uint256 runId)
    {
        runId = _nextRunId++;
        runs[runId] = Run({
            modelId: modelId,
            configHash: configHash,
            startedAt: uint64(block.timestamp),
            finalized: false,
            weightsHash: bytes32(0),
            metricsHash: bytes32(0),
            artifactsCID: "",
            finalizedAt: 0
        });
        emit TrainingStarted(runId, modelId, configHash);
    }

    function finalizeTrainingRun(
        uint256 runId,
        bytes32 weightsHash,
        bytes32 metricsHash,
        string calldata artifactsCID
    ) external whenNotPaused {
        Run storage R = runs[runId];
        require(R.modelId != bytes32(0), "run DNE");
        require(models[R.modelId].owner == msg.sender, "not model owner");
        require(!R.finalized, "already finalized");

        R.finalized   = true;
        R.weightsHash = weightsHash;
        R.metricsHash = metricsHash;
        R.artifactsCID = artifactsCID;
        R.finalizedAt = uint64(block.timestamp);

        emit TrainingFinalized(runId, R.modelId, weightsHash, metricsHash, artifactsCID);
    }

    /// Single inference (ok for demos)
    function logInference(
        bytes32 modelId,
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 xaiHash,
        string calldata xaiCID
    ) external whenNotPaused onlyModelOwner(modelId) {
        emit InferenceLogged(modelId, inputHash, outputHash, xaiHash, xaiCID);
    }

    /// NEW: O(1) batch commitment using a Merkle root of per-inference leaves.
    /// Off-chain you build leaves and the tree; on-chain we just commit the root.
    function commitInferenceBatch(
        bytes32 modelId,
        bytes32 batchRoot,
        uint256 count,
        string calldata batchCID
    ) external whenNotPaused onlyModelOwner(modelId) {
        require(batchRoot != bytes32(0), "root=0");
        require(count > 0, "count=0");
        emit InferenceBatchCommitted(modelId, batchRoot, count, batchCID);
    }

    /*────────────────────────── Views/Helpers ──────────────────────*/
    function getModel(bytes32 modelId) external view returns (Model memory) { return models[modelId]; }
    function getRun(uint256 runId) external view returns (Run memory) { return runs[runId]; }
    function peekRegistryRoot(bytes32 datasetId, uint256 datasetVersion) external view returns (bytes32) {
        return _fetchDatasetRoot(datasetId, datasetVersion);
    }

    /// Leaf = keccak256(inputHash || outputHash || xaiHash)
    function computeInferenceLeaf(
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 xaiHash
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(inputHash, outputHash, xaiHash));
    }

    /// Verify membership with the same "sorted-pair" rule used in Phase-1.
    function verifyBatchProof(
        bytes32 leaf,
        bytes32[] calldata proof,
        bytes32 root
    ) public pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            computed = (computed < p)
                ? keccak256(abi.encodePacked(computed, p))
                : keccak256(abi.encodePacked(p, computed));
        }
        return computed == root;
    }

    /// Convenience: build leaf on-chain from input/output/xai, then verify.
    function verifyBatchMembership(
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 xaiHash,
        bytes32[] calldata proof,
        bytes32 root
    ) external pure returns (bool) {
        return verifyBatchProof(computeInferenceLeaf(inputHash, outputHash, xaiHash), proof, root);
    }
 
 
    /*────────────────────────── Internal ───────────────────────────*/
    function _fetchDatasetRoot(bytes32 datasetId, uint256 version) internal view returns (bytes32) {
        bytes32 root;
        // Try explicit getter first
        try registry.getDatasetVersion(datasetId, version) returns (
            bytes32 merkleRoot,
            string memory,
            uint256,
            address,
            uint256
        ) {
            root = merkleRoot;
        } catch {
            if (version > 0) {
                uint256 idx = version - 1;
                try registry.datasets(datasetId, idx) returns (
                    bytes32 merkleRoot2,
                    string memory,
                    uint256,
                    address,
                    uint256
                ) {
                    root = merkleRoot2;
                } catch {
                    root = bytes32(0);
                }
            } else {
                root = bytes32(0);
            }
        }
        return root;
    }

    function _tryAnchorInRegistry(
        bytes32 modelId,
        bytes32 datasetId,
        uint256 datasetVersion,
        bytes32 trainingConfigHash
    ) internal returns (bool ok) {
        // Record was just created; owner is the true EOA we want to anchor as
        address ownerEOA = models[modelId].owner;

        // Preferred: new operator method (Phase-2 anchoring on behalf of ownerEOA)
        try registry.registerModelOperator(
            modelId,
            datasetId,
            datasetVersion,
            trainingConfigHash,
            ownerEOA
        ) {
            ok = true;
        } catch {
            // Backward-compat: older registries without the operator method
            try registry.registerModel(
                modelId,
                datasetId,
                datasetVersion,
                trainingConfigHash
            ) {
                ok = true;
            } catch {
                ok = false;
            }
        }
    }

}
