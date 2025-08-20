// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract DatasetRegistry {
    address public owner;
    mapping(address => bool) public authorized; // operators (e.g., Phase-2 contract)

    struct DatasetVersion {
        bytes32 merkleRoot;
        string  metadataCID; // IPFS CID
        uint256 timestamp;
        address registrant;
        uint256 version;     // 1-based
    }

    struct ModelRecord {
        bytes32 datasetId;
        uint256 datasetVersion;      // 1-based
        bytes32 trainingConfigHash;
        uint256 timestamp;
        address registrant;          // who’s recorded as owner/registrant of this model
    }

    // datasetId => array of versions
    mapping(bytes32 => DatasetVersion[]) public datasets;
    // modelId => ModelRecord
    mapping(bytes32 => ModelRecord) public models;

    /*─────────────── Events ───────────────*/
    event DatasetRegistered(
        bytes32 indexed datasetId,
        uint256 version,
        bytes32 merkleRoot,
        string  metadataCID,
        address indexed registrant,
        uint256 timestamp
    );

    event ModelRegistered(
        bytes32 indexed modelId,
        bytes32 indexed datasetId,
        uint256 datasetVersion,
        bytes32 trainingConfigHash,
        address indexed registrant,
        uint256 timestamp
    );

    event AuthorizationSet(address indexed addr, bool status);

    /*─────────────── Modifiers ───────────────*/
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAuthorized() {
        require(msg.sender == owner || authorized[msg.sender], "Not authorized");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setAuthorized(address _addr, bool _status) external onlyOwner {
        authorized[_addr] = _status;
        emit AuthorizationSet(_addr, _status);
    }

    /*─────────────── Dataset Functions ───────────────*/

    function registerDataset(
        bytes32 datasetId,
        bytes32 merkleRoot,
        string calldata metadataCID
    ) external onlyAuthorized {
        uint256 newVersion = datasets[datasetId].length + 1;

        datasets[datasetId].push(
            DatasetVersion({
                merkleRoot:  merkleRoot,
                metadataCID: metadataCID,
                timestamp:   block.timestamp,
                registrant:  msg.sender,
                version:     newVersion
            })
        );

        emit DatasetRegistered(
            datasetId,
            newVersion,
            merkleRoot,
            metadataCID,
            msg.sender,
            block.timestamp
        );
    }

    function getDatasetVersion(bytes32 datasetId, uint256 version)
        external
        view
        returns (
            bytes32 merkleRoot,
            string memory metadataCID,
            uint256 timestamp,
            address registrant,
            uint256 versionNum
        )
    {
        require(version > 0 && version <= datasets[datasetId].length, "Invalid dataset version");
        DatasetVersion storage dv = datasets[datasetId][version - 1];
        return (dv.merkleRoot, dv.metadataCID, dv.timestamp, dv.registrant, dv.version);
    }

    function getDatasetVersions(bytes32 datasetId)
        external
        view
        returns (DatasetVersion[] memory)
    {
        return datasets[datasetId];
    }

    function latestDatasetVersion(bytes32 datasetId) external view returns (uint256) {
        return datasets[datasetId].length;
    }

    /*─────────────── Model Functions ───────────────*/
    /// Path 1: Direct EOA registration (unchanged)
    function registerModel(
        bytes32 modelId,
        bytes32 datasetId,
        uint256 datasetVersion,
        bytes32 trainingConfigHash
    ) external onlyAuthorized {
        _registerModel(modelId, datasetId, datasetVersion, trainingConfigHash, msg.sender);
    }

    /// Path 2: Operator/Phase-2 registration on behalf of an EOA owner.
    /// NOTE: stores `ownerEOA` as `registrant`, so downstream reads see the true owner.
    function registerModelOperator(
        bytes32 modelId,
        bytes32 datasetId,
        uint256 datasetVersion,
        bytes32 trainingConfigHash,
        address ownerEOA
    ) external onlyAuthorized {
        require(ownerEOA != address(0), "owner=0");
        _registerModel(modelId, datasetId, datasetVersion, trainingConfigHash, ownerEOA);
    }

    function _registerModel(
        bytes32 modelId,
        bytes32 datasetId,
        uint256 datasetVersion,
        bytes32 trainingConfigHash,
        address registrant_
    ) internal {
        require(datasetVersion > 0 && datasetVersion <= datasets[datasetId].length, "Invalid dataset version");
        require(models[modelId].timestamp == 0, "Model already exists");

        models[modelId] = ModelRecord({
            datasetId:          datasetId,
            datasetVersion:     datasetVersion,
            trainingConfigHash: trainingConfigHash,
            timestamp:          block.timestamp,
            registrant:         registrant_
        });

        emit ModelRegistered(
            modelId,
            datasetId,
            datasetVersion,
            trainingConfigHash,
            registrant_,
            block.timestamp
        );
    }

    function getModel(bytes32 modelId) external view returns (ModelRecord memory) {
        return models[modelId];
    }

    /*─────────────── Utility Functions ───────────────*/

    function verifyFileHash(
        bytes32 datasetId,
        uint256 version,
        bytes32 leafHash,
        bytes32[] calldata proof
    ) public view returns (bool) {
        require(version > 0 && version <= datasets[datasetId].length, "Invalid dataset version");

        bytes32 computedHash = leafHash;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            computedHash = (computedHash < p)
                ? keccak256(abi.encodePacked(computedHash, p))
                : keccak256(abi.encodePacked(p, computedHash));
        }

        return computedHash == datasets[datasetId][version - 1].merkleRoot;
    }

    function computeDatasetId(string memory name) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(name));
    }
}
