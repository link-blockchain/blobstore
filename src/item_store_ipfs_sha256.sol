pragma solidity ^0.4.18;

import "./item_store_interface.sol";
import "./item_store_registry.sol";


/**
 * @title ItemStoreIpfsSha256
 * @author Jonathan Brown <jbrown@mix-blockchain.org>
 * @dev ItemStore implementation where each item revision is a SHA256 IPFS hash.
 */
contract ItemStoreIpfsSha256 is ItemStoreInterface {

    byte constant UPDATABLE = 0x01;           // True if the item is updatable. After creation can only be disabled.
    byte constant ENFORCE_REVISIONS = 0x02;   // True if the item is enforcing revisions. After creation can only be enabled.
    byte constant RETRACTABLE = 0x04;         // True if the item can be retracted. After creation can only be disabled.
    byte constant TRANSFERABLE = 0x08;        // True if the item can be transfered to another user or disowned. After creation can only be disabled.
    byte constant DISOWN = 0x10;              // True if the item should not have an owner at creation.

    /**
     * @dev Single slot structure of item state.
     */
    struct ItemState {
        bool inUse;             // Has this itemId ever been used.
        byte flags;             // Packed item settings.
        uint24 revisionCount;   // Number of revisions including revision 0.
        uint24 childCount;      // Number of children.
        uint32 timestamp;       // Timestamp of revision 0.
        address owner;          // Who owns this item.
    }

    /**
     * @dev Mapping of itemId to item state.
     */
    mapping (bytes32 => ItemState) itemState;

    /**
     * @dev Mapping of itemId to mapping of packed slots of eight 32-bit timestamps.
     */
    mapping (bytes32 => mapping (uint => bytes32)) packedTimestamps;

    /**
     * @dev Mapping of itemId to mapping of revision number to IPFS hash.
     */
    mapping (bytes32 => mapping (uint => bytes32)) itemRevisionIpfsHashes;

    /**
     * @dev Mapping of itemId to parent itemId.
     */
    mapping (bytes32 => bytes32) itemParent;

    /**
     * @dev Mapping of itemId to mapping of index to child itemId.
     */
    mapping (bytes32 => mapping(uint => bytes32)) itemChildren;

    /**
     * @dev Mapping of itemId to mapping of transfer recipient addresses to enabled.
     */
    mapping (bytes32 => mapping (address => bool)) enabledTransfers;

    /**
     * @dev Item Store Registry contract.
     */
    ItemStoreRegistry itemStoreRegistry;

    /**
     * @dev Id of this instance of ItemStore. Unique across all blockchains.
     */
    bytes32 contractId;

    /**
     * @dev An item revision has been published.
     * @param itemId Id of the item.
     * @param parent Optional itemId of the parent.
     * @param owner Address of the item owner.
     * @param flags Flags the item was created with.
     */
    event Create(bytes32 indexed itemId, bytes32 indexed parent, address indexed owner, bytes32 flags);

    /**
     * @dev An item revision has been published.
     * @param itemId Id of the item.
     * @param revisionId Id of the revision (the highest at time of logging).
     * @param ipfsHash Hash of the IPFS object where the item revision is stored.
     */
    event PublishRevision(bytes32 indexed itemId, uint revisionId, bytes32 ipfsHash);

    /**
     * @dev Revert if the itemId is not in use.
     * @param itemId Id of the item.
     */
    modifier inUse(bytes32 itemId) {
        require (itemState[itemId].inUse);
        _;
    }

    /**
     * @dev Revert if the owner of the item is not the message sender.
     * @param itemId Id of the item.
     */
    modifier isOwner(bytes32 itemId) {
        require (itemState[itemId].owner == msg.sender);
        _;
    }

    /**
     * @dev Revert if the item is not updatable.
     * @param itemId Id of the item.
     */
    modifier isUpdatable(bytes32 itemId) {
        require (itemState[itemId].flags & UPDATABLE != 0);
        _;
    }

    /**
     * @dev Revert if the item is not enforcing revisions.
     * @param itemId Id of the item.
     */
    modifier isNotEnforceRevisions(bytes32 itemId) {
        require (itemState[itemId].flags & ENFORCE_REVISIONS == 0);
        _;
    }

    /**
     * @dev Revert if the item is not retractable.
     * @param itemId Id of the item.
     */
    modifier isRetractable(bytes32 itemId) {
        require (itemState[itemId].flags & RETRACTABLE != 0);
        _;
    }

    /**
     * @dev Revert if the item is not transferable.
     * @param itemId Id of the item.
     */
    modifier isTransferable(bytes32 itemId) {
        require (itemState[itemId].flags & TRANSFERABLE != 0);
        _;
    }

    /**
     * @dev Revert if the item is not transferable to a specific user.
     * @param itemId Id of the item.
     * @param recipient Address of the user.
     */
    modifier isTransferEnabled(bytes32 itemId, address recipient) {
        require (enabledTransfers[itemId][recipient]);
        _;
    }

    /**
     * @dev Revert if the item only has one revision.
     * @param itemId Id of the item.
     */
    modifier hasAdditionalRevisions(bytes32 itemId) {
        require (itemState[itemId].revisionCount > 1);
        _;
    }

    /**
     * @dev Revert if a specific item revision does not exist.
     * @param itemId Id of the item.
     * @param revisionId Id of the revision.
     */
    modifier revisionExists(bytes32 itemId, uint revisionId) {
        require (revisionId < itemState[itemId].revisionCount);
        _;
    }

    /**
     * @dev Revert if a specific item child does not exist.
     * @param itemId Id of the item.
     * @param i Index of the child.
     */
    modifier childExists(bytes32 itemId, uint i) {
        require (i < itemState[itemId].childCount);
        _;
    }

    /**
     * @dev Constructor.
     * @param _itemStoreRegistry Address of ItemStoreRegistry contract to register with.
     */
    function ItemStoreIpfsSha256(ItemStoreRegistry _itemStoreRegistry) public {
        // Store the addresses of the contracts.
        itemStoreRegistry = _itemStoreRegistry;
        // Create id for this contract.
        contractId = bytes12(keccak256(this, block.blockhash(block.number - 1)));
        // Register this contract.
        itemStoreRegistry.register(contractId);
    }

    /**
     * @dev Creates a new item. It is guaranteed that different users will never receive the same itemId, even before consensus has been reached. This prevents itemId sniping.
     * @param flagsNonce Nonce that this address has never passed before; first byte is creation flags.
     * @param ipfsHash Hash of the IPFS object where revision 0 is stored.
     * @return itemId Id of the item.
     */
    function create(bytes32 flagsNonce, bytes32 ipfsHash) external returns (bytes32 itemId) {
        // Generate the itemId.
        itemId = contractId | (keccak256(msg.sender, flagsNonce) & bytes32(uint160(-1)));
        // Make sure this itemId has not been used before.
        require (!itemState[itemId].inUse);
        // Extract the flags.
        bytes32 flags = byte(flagsNonce);
        // Determine the owner.
        address owner = (flags & DISOWN == 0) ? msg.sender : 0;
        // Store item state.
        itemState[itemId] = ItemState({
            inUse: true,
            flags: byte(flags),
            childCount: 0,
            revisionCount: 1,
            timestamp: uint32(block.timestamp),
            owner: owner
        });
        // Store the IPFS hash.
        itemRevisionIpfsHashes[itemId][0] = ipfsHash;
        // Log item creation.
        Create(itemId, 0, owner, flags);
        // Log the first revision.
        PublishRevision(itemId, 0, ipfsHash);
    }

    /**
     * @dev Creates a new item. It is guaranteed that different users will never receive the same itemId, even before consensus has been reached. This prevents itemId sniping.
     * @param flagsNonce Nonce that this address has never passed before; first byte is creation flags.
     * @param ipfsHash Hash of the IPFS object where revision 0 is stored.
     * @param parent Optional itemId of parent.
     * @return itemId Id of the item.
     */
    function createWithParent(bytes32 flagsNonce, bytes32 ipfsHash, bytes32 parent) external returns (bytes32 itemId) {
        // Generate the itemId.
        itemId = contractId | (keccak256(msg.sender, flagsNonce) & bytes32(uint160(-1)));
        // Make sure this itemId has not been used before.
        require (!itemState[itemId].inUse);
        // Ensure child and parent are not the same.
        require (itemId != parent);
        // Extract the flags.
        bytes32 flags = byte(flagsNonce);
        // Determine the owner.
        address owner = (flags & DISOWN == 0) ? msg.sender : 0;
        // Store item state.
        itemState[itemId] = ItemState({
            inUse: true,
            flags: byte(flags),
            childCount: 0,
            revisionCount: 1,
            timestamp: uint32(block.timestamp),
            owner: owner
        });
        // Store the parent.
        itemParent[itemId] = parent;
        // Is the parent in this item store contract?
        if (bytes12(parent) == contractId) {
            // Ensure the parent exists.
            require (getInUse(parent));
            // Attach the item to the parent.
            itemChildren[parent][itemState[parent].childCount++] = itemId;
            // Log the child.
            AddChild(parent, itemId);
        }
        else {
            itemStoreRegistry.getItemStore(bytes12(parent)).addForeignChild(parent, itemId);
        }
        // Store the IPFS hash.
        itemRevisionIpfsHashes[itemId][0] = ipfsHash;
        // Log item creation.
        Create(itemId, parent, owner, flags);
        // Log the first revision.
        PublishRevision(itemId, 0, ipfsHash);
    }

    /**
     * @dev Add a child from another item store contract.
     * @param itemId itemId of parent.
     * @param child itemId of child.
     */
    function addForeignChild(bytes32 itemId, bytes32 child) external inUse(itemId) {
        // Ensure the child has recorded the parent.
        require (itemStoreRegistry.getItemStore(bytes12(child)).getParent(child) == itemId);
        // Store the new child.
        itemChildren[itemId][itemState[itemId].childCount++] = child;
        // Log the child.
        AddChild(itemId, child);
    }

    /**
     * @dev Store an item revision timestamp in a packed slot.
     * @param itemId Id of the item.
     * @param offset The offset of the timestamp that should be stored.
     */
    function _setPackedTimestamp(bytes32 itemId, uint offset) internal {
        // Get the slot.
        bytes32 slot = packedTimestamps[itemId][offset / 8];
        // Calculate the shift.
        uint shift = (offset % 8) * 32;
        // Wipe the previous timestamp.
        slot &= ~(bytes32(uint32(-1)) << shift);
        // Insert the current timestamp.
        slot |= bytes32(uint32(block.timestamp)) << shift;
        // Store the slot.
        packedTimestamps[itemId][offset / 8] = slot;
    }

    /**
     * @dev Create a new item revision.
     * @param itemId Id of the item.
     * @param ipfsHash Hash of the IPFS object where the item revision is stored.
     * @return revisionId The new revisionId.
     */
    function createNewRevision(bytes32 itemId, bytes32 ipfsHash) external isOwner(itemId) isUpdatable(itemId) returns (uint revisionId) {
        // Increment the number of revisions.
        revisionId = itemState[itemId].revisionCount++;
        // Store the IPFS hash.
        itemRevisionIpfsHashes[itemId][revisionId] = ipfsHash;
        // Store the timestamp.
        _setPackedTimestamp(itemId, revisionId - 1);
        // Log the revision.
        PublishRevision(itemId, revisionId, ipfsHash);
    }

    /**
     * @dev Update an item's latest revision.
     * @param itemId Id of the item.
     * @param ipfsHash Hash of the IPFS object where the item revision is stored.
     */
    function updateLatestRevision(bytes32 itemId, bytes32 ipfsHash) external isOwner(itemId) isUpdatable(itemId) isNotEnforceRevisions(itemId) {
        // Get item state.
        ItemState storage state = itemState[itemId];
        // Determine the revisionId.
        uint revisionId = state.revisionCount - 1;
        // Update the IPFS hash.
        itemRevisionIpfsHashes[itemId][revisionId] = ipfsHash;
        // Update the timestamp.
        if (revisionId == 0) {
            state.timestamp = uint32(block.timestamp);
        }
        else {
            _setPackedTimestamp(itemId, revisionId - 1);
        }
        // Log the revision.
        PublishRevision(itemId, revisionId, ipfsHash);
    }

    /**
     * @dev Retract an item's latest revision. Revision 0 cannot be retracted.
     * @param itemId Id of the item.
     */
    function retractLatestRevision(bytes32 itemId) external isOwner(itemId) isUpdatable(itemId) isNotEnforceRevisions(itemId) hasAdditionalRevisions(itemId) {
        // Decrement the number of revisions.
        uint revisionId = --itemState[itemId].revisionCount;
        // Delete the IPFS hash.
        delete itemRevisionIpfsHashes[itemId][revisionId];
        // Delete the packed timestamp slot if it is no longer required.
        if (revisionId % 8 == 1) {
            delete packedTimestamps[itemId][revisionId / 8];
        }
        // Log the revision retraction.
        RetractRevision(itemId, revisionId);
    }

    /**
     * @dev Delete all of an item's packed revision timestamps.
     * @param itemId Id of the item.
     */
    function _deleteAllPackedRevisionTimestamps(bytes32 itemId) internal {
        // Determine how many slots should be deleted.
        // Timestamp of the first revision is stored in the item state, so the first slot only needs to be deleted if there are at least 2 revisions.
        uint slotCount = (itemState[itemId].revisionCount + 6) / 8;
        // Delete the slots.
        for (uint i = 0; i < slotCount; i++) {
            delete packedTimestamps[itemId][i];
        }
    }

    /**
     * @dev Delete all an item's revisions and replace it with a new item.
     * @param itemId Id of the item.
     * @param ipfsHash Hash of the IPFS object where the item revision is stored.
     */
    function restart(bytes32 itemId, bytes32 ipfsHash) external isOwner(itemId) isUpdatable(itemId) isNotEnforceRevisions(itemId) {
        // Delete all the IPFS hashes except the first one.
        for (uint i = 1; i < itemState[itemId].revisionCount; i++) {
            delete itemRevisionIpfsHashes[itemId][i];
        }
        // Delete the packed revision timestamps.
        _deleteAllPackedRevisionTimestamps(itemId);
        // Update the item state.
        itemState[itemId].revisionCount = 1;
        itemState[itemId].timestamp = uint32(block.timestamp);
        // Update the first IPFS hash.
        itemRevisionIpfsHashes[itemId][0] = ipfsHash;
        // Log the revision.
        PublishRevision(itemId, 0, ipfsHash);
    }

    /**
     * @dev Retract an item.
     * @param itemId Id of the item. This itemId can never be used again.
     */
    function retract(bytes32 itemId) external isOwner(itemId) isRetractable(itemId) {
        // Delete all the IPFS hashes.
        for (uint i = 0; i < itemState[itemId].revisionCount; i++) {
            delete itemRevisionIpfsHashes[itemId][i];
        }
        // Mark this item as retracted.
        itemState[itemId] = ItemState({
            inUse: true,
            flags: 0,
            childCount: itemState[itemId].childCount,
            revisionCount: 0,
            timestamp: 0,
            owner: 0
        });
        // Log the item retraction.
        Retract(itemId);
    }

    /**
     * @dev Enable transfer of the item to the current user.
     * @param itemId Id of the item.
     */
    function transferEnable(bytes32 itemId) external isTransferable(itemId) {
        // Record in state that the current user will accept this item.
        enabledTransfers[itemId][msg.sender] = true;
    }

    /**
     * @dev Disable transfer of the item to the current user.
     * @param itemId Id of the item.
     */
    function transferDisable(bytes32 itemId) external isTransferEnabled(itemId, msg.sender) {
        // Record in state that the current user will not accept this item.
        enabledTransfers[itemId][msg.sender] = false;
    }

    /**
     * @dev Transfer an item to a new user.
     * @param itemId Id of the item.
     * @param recipient Address of the user to transfer to item to.
     */
    function transfer(bytes32 itemId, address recipient) external isOwner(itemId) isTransferable(itemId) isTransferEnabled(itemId, recipient) {
        // Update ownership of the item.
        itemState[itemId].owner = recipient;
        // Disable this transfer in future and free up the slot.
        enabledTransfers[itemId][recipient] = false;
        // Log the transfer.
        Transfer(itemId, recipient);
    }

    /**
     * @dev Disown an item.
     * @param itemId Id of the item.
     */
    function disown(bytes32 itemId) external isOwner(itemId) isTransferable(itemId) {
        // Remove the owner from the item's state.
        delete itemState[itemId].owner;
        // Log that the item has been disowned.
        Disown(itemId);
    }

    /**
     * @dev Set an item as not updatable.
     * @param itemId Id of the item.
     */
    function setNotUpdatable(bytes32 itemId) external isOwner(itemId) {
        // Record in state that the item is not updatable.
        itemState[itemId].flags &= ~UPDATABLE;
        // Log that the item is not updatable.
        SetNotUpdatable(itemId);
    }

    /**
     * @dev Set an item to enforce revisions.
     * @param itemId Id of the item.
     */
    function setEnforceRevisions(bytes32 itemId) external isOwner(itemId) {
        // Record in state that all changes to this item must be new revisions.
        itemState[itemId].flags |= ENFORCE_REVISIONS;
        // Log that the item now enforces new revisions.
        SetEnforceRevisions(itemId);
    }

    /**
     * @dev Set an item to not be retractable.
     * @param itemId Id of the item.
     */
    function setNotRetractable(bytes32 itemId) external isOwner(itemId) {
        // Record in state that the item is not retractable.
        itemState[itemId].flags &= ~RETRACTABLE;
        // Log that the item is not retractable.
        SetNotRetractable(itemId);
    }

    /**
     * @dev Set an item to not be transferable.
     * @param itemId Id of the item.
     */
    function setNotTransferable(bytes32 itemId) external isOwner(itemId) {
        // Record in state that the item is not transferable.
        itemState[itemId].flags &= ~TRANSFERABLE;
        // Log that the item is not transferable.
        SetNotTransferable(itemId);
    }

    /**
     * @dev Get the id for this ItemStore contract.
     * @return Id of the contract.
     */
    function getContractId() external view returns (bytes32) {
        return contractId;
    }

    /**
     * @dev Check if an itemId is in use.
     * @param itemId Id of the item.
     * @return True if the itemId is in use.
     */
    function getInUse(bytes32 itemId) public view returns (bool) {
        return itemState[itemId].inUse;
    }

    /**
     * @dev Get the IPFS hashes for all of an item's revisions.
     * @param itemId Id of the item.
     * @return ipfsHashes Revision IPFS hashes.
     */
    function _getAllRevisionIpfsHashes(bytes32 itemId) internal view returns (bytes32[] ipfsHashes) {
        uint revisionCount = itemState[itemId].revisionCount;
        ipfsHashes = new bytes32[](revisionCount);
        for (uint revisionId = 0; revisionId < revisionCount; revisionId++) {
            ipfsHashes[revisionId] = itemRevisionIpfsHashes[itemId][revisionId];
        }
    }

    /**
     * @dev Get the timestamp for a specific item revision.
     * @param itemId Id of the item.
     * @param revisionId Id of the revision.
     * @return timestamp Timestamp of the specified revision.
     */
    function _getRevisionTimestamp(bytes32 itemId, uint revisionId) internal view returns (uint timestamp) {
        if (revisionId == 0) {
            timestamp = itemState[itemId].timestamp;
        }
        else {
            uint offset = revisionId - 1;
            timestamp = uint32(packedTimestamps[itemId][offset / 8] >> ((offset % 8) * 32));
        }
    }

    /**
     * @dev Get the timestamps for all of an item's revisions.
     * @param itemId Id of the item.
     * @return timestamps Revision timestamps.
     */
    function _getAllRevisionTimestamps(bytes32 itemId) internal view returns (uint[] timestamps) {
        uint count = itemState[itemId].revisionCount;
        timestamps = new uint[](count);
        for (uint revisionId = 0; revisionId < count; revisionId++) {
            timestamps[revisionId] = _getRevisionTimestamp(itemId, revisionId);
        }
    }

    /**
     * @dev Get all of an item's children.
     * @param itemId Id of the item.
     * @return children itemIds of the children.
     */
    function _getAllChildren(bytes32 itemId) internal view returns (bytes32[] children) {
        uint count = itemState[itemId].childCount;
        children = new bytes32[](count);
        for (uint i = 0; i < count; i++) {
            children[i] = itemChildren[itemId][i];
        }
    }

    /**
     * @dev Get item state.
     * @param itemId Id of the item.
     * @return flags Packed item settings.
     * @return owner Owner of the item.
     * @return revisionCount How many revisions the item has.
     * @return ipfsHashes IPFS hash of each revision.
     * @return timestamps Timestamp of each revision.
     */
    function getState(bytes32 itemId) external view inUse(itemId) returns (bytes32 flags, address owner, uint revisionCount, bytes32[] ipfsHashes, uint[] timestamps, bytes32 parent, bytes32[] children) {
        ItemState storage state = itemState[itemId];
        flags = state.flags;
        owner = state.owner;
        revisionCount = state.revisionCount;
        ipfsHashes = _getAllRevisionIpfsHashes(itemId);
        timestamps = _getAllRevisionTimestamps(itemId);
        parent = itemParent[itemId];
        children = _getAllChildren(itemId);
    }

    /**
     * @dev Get all an item's flags.
     * @param itemId Id of the item.
     * @return Packed item settings.
     */
    function getFlags(bytes32 itemId) external view inUse(itemId) returns (bytes32) {
        return itemState[itemId].flags;
    }

    /**
     * @dev Determine if an item is updatable.
     * @param itemId Id of the item.
     * @return True if the item is updatable.
     */
    function getUpdatable(bytes32 itemId) external view inUse(itemId) returns (bool) {
        return itemState[itemId].flags & UPDATABLE != 0;
    }

    /**
     * @dev Determine if an item enforces revisions.
     * @param itemId Id of the item.
     * @return True if the item enforces revisions.
     */
    function getEnforceRevisions(bytes32 itemId) external view inUse(itemId) returns (bool) {
        return itemState[itemId].flags & ENFORCE_REVISIONS != 0;
    }

    /**
     * @dev Determine if an item is retractable.
     * @param itemId Id of the item.
     * @return True if the item is item retractable.
     */
    function getRetractable(bytes32 itemId) external view inUse(itemId) returns (bool) {
        return itemState[itemId].flags & RETRACTABLE != 0;
    }

    /**
     * @dev Determine if an item is transferable.
     * @param itemId Id of the item.
     * @return True if the item is transferable.
     */
    function getTransferable(bytes32 itemId) external view inUse(itemId) returns (bool) {
        return itemState[itemId].flags & TRANSFERABLE != 0;
    }

    /**
     * @dev Get the owner of an item.
     * @param itemId Id of the item.
     * @return Owner of the item.
     */
    function getOwner(bytes32 itemId) external view inUse(itemId) returns (address) {
        return itemState[itemId].owner;
    }

    /**
     * @dev Get the number of revisions an item has.
     * @param itemId Id of the item.
     * @return How many revisions the item has.
     */
    function getRevisionCount(bytes32 itemId) external view inUse(itemId) returns (uint) {
        return itemState[itemId].revisionCount;
    }

   /**
    * @dev Get the IPFS hash for a specific item revision.
    * @param itemId Id of the item.
    * @param revisionId Id of the revision.
    * @return IPFS hash of the specified revision.
    */
    function getRevisionIpfsHash(bytes32 itemId, uint revisionId) external view revisionExists(itemId, revisionId) returns (bytes32) {
        return itemRevisionIpfsHashes[itemId][revisionId];
    }

    /**
     * @dev Get the IPFS hashes for all of an item's revisions.
     * @param itemId Id of the item.
     * @return IPFS hashes of all revisions of the item.
     */
    function getAllRevisionIpfsHashes(bytes32 itemId) external view inUse(itemId) returns (bytes32[]) {
        return _getAllRevisionIpfsHashes(itemId);
    }

    /**
     * @dev Get the timestamp for a specific item revision.
     * @param itemId Id of the item.
     * @param revisionId Id of the revision.
     * @return Timestamp of the specified revision.
     */
    function getRevisionTimestamp(bytes32 itemId, uint revisionId) external view revisionExists(itemId, revisionId) returns (uint) {
        return _getRevisionTimestamp(itemId, revisionId);
    }

    /**
     * @dev Get the timestamps for all of an item's revisions.
     * @param itemId Id of the item.
     * @return Timestamps of all revisions of the item.
     */
    function getAllRevisionTimestamps(bytes32 itemId) external view inUse(itemId) returns (uint[]) {
        return _getAllRevisionTimestamps(itemId);
    }

    /**
     * @dev Get all an items parent.
     * @param itemId Id of the item.
     * @return itemId of parent.
     */
    function getParent(bytes32 itemId) external view inUse(itemId) returns (bytes32) {
        return itemParent[itemId];
    }

    /**
     * @dev Get the number of children an item has.
     * @param itemId Id of the item.
     * @return How many children the item has.
     */
    function getChildCount(bytes32 itemId) external view inUse(itemId) returns (uint) {
        return itemState[itemId].childCount;
    }

    /**
     * @dev Get a specific child
     * @param itemId Id of the item.
     * @param i Index of the child.
     * @return itemId of the child.
     */
    function getChild(bytes32 itemId, uint i) external view childExists(itemId, i) returns (bytes32) {
        return itemChildren[itemId][i];
    }

    /**
     * @dev Get all of an item's children.
     * @param itemId Id of the item.
     * @return itemIds of the children.
     */
    function getAllChildren(bytes32 itemId) external view inUse(itemId) returns (bytes32[]) {
        return _getAllChildren(itemId);
    }

}
