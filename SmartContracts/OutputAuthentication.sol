// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* ========= Phase-2 interface (EXACT match to your ModelTrainingAndInference) ========= */
interface IModelTrainingAndInference {
    struct Model {
        address owner;
        bytes32 datasetId;
        uint256 datasetVersion;
        bytes32 datasetRoot;
        bytes32 codeHash;
        bytes32 archHash;
        string  modelURI;
        uint64  createdAt;
    }
    function modelExists(bytes32 modelId) external view returns (bool);
    function getModel(bytes32 modelId) external view returns (Model memory);
}

/* ================================ Phase-3: OutputAuthentication ================================ */
contract OutputAuthentication {
    /* ─────────────── Storage ─────────────── */
    IModelTrainingAndInference public immutable phase2;

    // allow-list of publishers per modelId (simple allow flag)
    mapping(bytes32 => mapping(address => bool)) public isPublisher;

    // time-bounded publisher windows per modelId
    struct PublisherRule {
        bool   allowed;      // mirrors isPublisher but scoped here for windowing
        uint64 start;        // inclusive unix time (0 = no lower bound)
        uint64 end;          // inclusive unix time (type(uint64).max = no upper bound)
    }
    mapping(bytes32 => mapping(address => PublisherRule)) public publisherRules;

    // revocation maps (model-scoped)
    mapping(bytes32 => mapping(bytes32 => bool)) public revokedLeaf;       // leaf := keccak(input||output||xai)
    mapping(bytes32 => mapping(bytes32 => bool)) public revokedBatchRoot;  // full batch root

    // Optional on-chain record for raw content hashes
    struct Record {
        address submitter;
        bytes32 modelId;
        bytes32 batchRoot;
        string  xaiCID;
        uint64  timestamp;
    }
    mapping(bytes32 => Record) public records; // contentHash => record

    /* ─────────────── Events ─────────────── */
    event PublisherSet(bytes32 indexed modelId, address indexed publisher, bool allowed);
    event PublisherWindowSet(bytes32 indexed modelId, address indexed publisher, bool allowed, uint64 start, uint64 end);
    event PublisherRevoked(bytes32 indexed modelId, address indexed publisher, uint64 at);

    event LeafRevoked(bytes32 indexed modelId, bytes32 indexed leaf, address indexed by, uint64 at);
    event LeafUnrevoked(bytes32 indexed modelId, bytes32 indexed leaf, address indexed by, uint64 at);
    event BatchRootRevoked(bytes32 indexed modelId, bytes32 indexed root, address indexed by, uint64 at);
    event BatchRootUnrevoked(bytes32 indexed modelId, bytes32 indexed root, address indexed by, uint64 at);

    event ContentStored(
        bytes32 indexed modelId,
        bytes32 indexed contentHash,
        bytes32 indexed batchRoot,
        address submitter,
        string  xaiCID,
        uint64  timestamp
    );

    /* ─────────────── Custom errors ─────────────── */
    error ModelDoesNotExist(bytes32 modelId);
    error NotModelOwner(address caller, address owner, bytes32 modelId);

    /* ─────────────── Constructor ─────────────── */
    constructor(address phase2_) {
        require(phase2_ != address(0), "phase2=0");
        phase2 = IModelTrainingAndInference(phase2_);
    }

    /* ─────────────── Owner & Auth ─────────────── */
    function ownerOf(bytes32 modelId) public view returns (address owner) {
        IModelTrainingAndInference.Model memory m = phase2.getModel(modelId);
        owner = m.owner;
    }

    // unified auth predicate (used for both writes and receipt checks)
    function _isAuthorizedAt(bytes32 modelId, address actor, uint64 ts) internal view returns (bool) {
        address o = ownerOf(modelId);
        if (actor == o) return true; // owner always valid
        PublisherRule memory pr = publisherRules[modelId][actor];
        if (!pr.allowed) return false;
        if (ts < pr.start) return false;
        if (ts > pr.end) return false;
        return true;
    }

    modifier onlyModelOwner(bytes32 modelId) {
        if (!phase2.modelExists(modelId)) revert ModelDoesNotExist(modelId);
        address o = ownerOf(modelId);
        if (msg.sender != o) revert NotModelOwner(msg.sender, o, modelId);
        _;
    }

    // IMPORTANT: now enforces publisher window (not just the boolean flag)
    modifier onlyAuthorized(bytes32 modelId) {
        if (!phase2.modelExists(modelId)) revert ModelDoesNotExist(modelId);
        if (!_isAuthorizedAt(modelId, msg.sender, uint64(block.timestamp))) {
            address o = ownerOf(modelId);
            revert NotModelOwner(msg.sender, o, modelId);
        }
        _;
    }

    // Back-compat: simple allow/deny (window = wide open)
    function setPublisher(bytes32 modelId, address publisher, bool allowed)
        external
        onlyModelOwner(modelId)
    {
        require(publisher != address(0), "publisher=0");
        isPublisher[modelId][publisher] = allowed;
        publisherRules[modelId][publisher] = PublisherRule({
            allowed: allowed,
            start: 0,
            end: type(uint64).max
        });
        emit PublisherSet(modelId, publisher, allowed);
        emit PublisherWindowSet(modelId, publisher, allowed, 0, type(uint64).max);
    }

    // Explicit time window controls
    function setPublisherWindow(
        bytes32 modelId,
        address publisher,
        bool allowed,
        uint64 start,
        uint64 end
    ) external onlyModelOwner(modelId) {
        require(publisher != address(0), "publisher=0");
        if (end < start) {
            end = start - 1; // closed window
        }
        isPublisher[modelId][publisher] = allowed;
        publisherRules[modelId][publisher] = PublisherRule({
            allowed: allowed,
            start: start,
            end: end
        });
        emit PublisherWindowSet(modelId, publisher, allowed, start, end);
    }

    // Immediate revoke convenience
    function revokePublisher(bytes32 modelId, address publisher)
        external
        onlyModelOwner(modelId)
    {
        isPublisher[modelId][publisher] = false;
        PublisherRule storage pr = publisherRules[modelId][publisher];
        pr.allowed = false;
        pr.end = uint64(block.timestamp);
        emit PublisherRevoked(modelId, publisher, uint64(block.timestamp));
    }

    // View helper for UI/Colab
    function isPublisherActive(bytes32 modelId, address publisher) external view returns (bool) {
        return _isAuthorizedAt(modelId, publisher, uint64(block.timestamp));
    }

    /* ─────────────── Merkle helpers ─────────────── */
    function computeInferenceLeaf(
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 xaiHash
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(inputHash, outputHash, xaiHash));
    }

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

    function verifyBatchMembership(
        bytes32 inputHash,
        bytes32 outputHash,
        bytes32 xaiHash,
        bytes32[] calldata proof,
        bytes32 root
    ) external pure returns (bool) {
        return verifyBatchProof(computeInferenceLeaf(inputHash, outputHash, xaiHash), proof, root);
    }

    /* ─────────────── EIP-712 (rich receipt) ─────────────── */
    struct Receipt {
        bytes32 modelId;
        bytes32 weightsHash;
        bytes32 batchRoot;
        string  batchCID;
        bytes32 txHash;
        uint256 index;
        bytes32 leaf;
        address publisher;
        uint64  timestamp;
    }

    bytes32 private constant EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant RECEIPT_TYPEHASH = keccak256(
        "Receipt(bytes32 modelId,bytes32 weightsHash,bytes32 batchRoot,string batchCID,bytes32 txHash,uint256 index,bytes32 leaf,address publisher,uint64 timestamp)"
    );

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH,
                keccak256(bytes("LLMOutputReceipt")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function hashReceipt(Receipt memory r) public view returns (bytes32 digest) {
        bytes32 batchCIDHash = keccak256(bytes(r.batchCID));
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIPT_TYPEHASH,
                r.modelId,
                r.weightsHash,
                r.batchRoot,
                batchCIDHash,
                r.txHash,
                r.index,
                r.leaf,
                r.publisher,
                r.timestamp
            )
        );
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function recoverSigner(bytes32 digest, bytes memory sig) public pure returns (address) {
        require(sig.length == 65, "sig!=65");
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "bad v");
        return ecrecover(digest, v, r, s);
    }

    function verifyReceipt(Receipt memory r, bytes memory signature)
        external
        view
        returns (bool ok, address signer)
    {
        signer = recoverSigner(hashReceipt(r), signature);
        if (signer != r.publisher) return (false, signer); // must match claimed publisher

        // owner or active publisher (windowed)
        if (!_isAuthorizedAt(r.modelId, signer, r.timestamp)) return (false, signer);

        // revocation checks
        if (revokedLeaf[r.modelId][r.leaf]) return (false, signer);
        if (revokedBatchRoot[r.modelId][r.batchRoot]) return (false, signer);

        return (true, signer);
    }

    function verifyReceiptAndMembership(
        Receipt memory r,
        bytes memory signature,
        bytes32[] calldata proof
    ) external view returns (bool ok, address signer) {
        (bool okSig, address s) = this.verifyReceipt(r, signature);
        if (!okSig) return (false, s);
        bool okMem = verifyBatchProof(r.leaf, proof, r.batchRoot);
        if (!okMem) return (false, s);
        return (true, s);
    }

    /* ─────────────── Revocation controls ─────────────── */
    function revokeLeaf(bytes32 modelId, bytes32 leaf) external onlyModelOwner(modelId) {
        revokedLeaf[modelId][leaf] = true;
        emit LeafRevoked(modelId, leaf, msg.sender, uint64(block.timestamp));
    }

    function unRevokeLeaf(bytes32 modelId, bytes32 leaf) external onlyModelOwner(modelId) {
        revokedLeaf[modelId][leaf] = false;
        emit LeafUnrevoked(modelId, leaf, msg.sender, uint64(block.timestamp));
    }

    function revokeBatchRoot(bytes32 modelId, bytes32 root) external onlyModelOwner(modelId) {
        revokedBatchRoot[modelId][root] = true;
        emit BatchRootRevoked(modelId, root, msg.sender, uint64(block.timestamp));
    }

    function unRevokeBatchRoot(bytes32 modelId, bytes32 root) external onlyModelOwner(modelId) {
        revokedBatchRoot[modelId][root] = false;
        emit BatchRootUnrevoked(modelId, root, msg.sender, uint64(block.timestamp));
    }

    /* ─────────────── Store content hash (owner or publisher) ─────────────── */
    function storeContentHash(
        bytes32 modelId,
        bytes32 contentHash,
        bytes32 batchRoot,
        string calldata xaiCID
    ) external onlyAuthorized(modelId) {
        require(contentHash != bytes32(0), "hash=0");
        require(records[contentHash].timestamp == 0, "already stored");

        records[contentHash] = Record({
            submitter: msg.sender,
            modelId:   modelId,
            batchRoot: batchRoot,
            xaiCID:    xaiCID,
            timestamp: uint64(block.timestamp)
        });

        emit ContentStored(
            modelId,
            contentHash,
            batchRoot,
            msg.sender,
            xaiCID,
            uint64(block.timestamp)
        );
    }

    // Reads to support Colab/UI
    function exists(bytes32 contentHash) external view returns (bool) {
        return records[contentHash].timestamp != 0;
    }

    function getRecord(bytes32 contentHash) external view returns (Record memory) {
        return records[contentHash];
    }

    /* ─────────────── Debug helper ─────────────── */
    function debugOwnerAndSender(bytes32 modelId)
        external
        view
        returns (address owner, address sender, address phase2Addr)
    {
        owner = ownerOf(modelId);
        sender = msg.sender;
        phase2Addr = address(phase2);
    }
}
