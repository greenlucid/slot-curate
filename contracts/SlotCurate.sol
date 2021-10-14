/**
 * @authors: @greenlucid
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 * SPDX-License-Identifier: Licenses are not real
 */
 
 pragma solidity ^0.8.9;

/*
    things to think about
    
    do I disallow the possibility of users submitting to a random, far away unused slot?
    or, just let them do it?
    yeah cuz its cheaper that way. there's no damage to cause anyway.
    
    ItemRemoved and ItemAdded are the same contract wise
    An optimization would be to just have an SlotExecuted with the slot and the enum
    So there are no branches figuring out which one, and it's slightly cheaper to deploy.

*/

contract SlotCurate {
    
    enum ProcessType {
        Add,
        Removal
    }
    
    // you can compress the bools / enums into a byte variable.
    // that + uint32 timestamp, means there are 7 vacant bytes per slot.
    // but we only need to know the slot to identify the dispute, so why bother?
    // if ids turn out to be needed, that's fine, there's enough space.
    struct Slot {
        bool used;
        ProcessType processType;
        bool beingDisputed;
        uint72 submissionTime;
        address requester;
    }
    
    struct Dispute {
        uint32 slot; // could be adjusted, because its massive.
        uint todo;
    }
    
    // EVENTS //
    
    event ItemAddRequest(uint _slotIndex, string _ipfsUri);
    event ItemAdded(uint _slotIndex);
    event ItemRemovalRequest(uint _workSlot, uint _idSlot, uint _idSubmissionTime);
    event ItemRemoved(uint _slotIndex);
    
    
    // CONTRACT STORAGE //
    // these cannot be changed after deployment.
    string rulesIpfs;
    uint submissionPeriod;
    uint requesterStake;
    uint challengerStake;
    
    mapping(uint256 => Slot) slots;
    mapping(uint256 => Dispute) disputes;
    
    constructor(string memory _rulesIpfs, uint _submissionPeriod, uint _requesterStake, uint _challengerStake) {
        rulesIpfs = _rulesIpfs;
        submissionPeriod = _submissionPeriod;
        requesterStake = _requesterStake;
        challengerStake = _challengerStake;
    }
    
    // PUBLIC FUNCTIONS
    
    // no refunds for overpaying. consider it burned. refunds are bloat.
    function addItem(uint _slotIndex, string memory _ipfsUri) public payable {
        Slot storage slot = slots[_slotIndex];
        require(slot.used == false, "Slot must not be in use");
        require(msg.value >= requesterStake, "This is not enough to cover initial stake");
        slot.used = true;
        slot.processType = ProcessType.Add;
        slot.beingDisputed = false;
        slot.submissionTime = uint72(block.timestamp);
        slot.requester = msg.sender;
        emit ItemAddRequest(_slotIndex, _ipfsUri);
    }
    
    function removeItem(uint _workSlot, uint _idSlot, uint _idSubmissionTime) public payable {
        Slot storage slot = slots[_workSlot];
        require(slot.used == false, "Slot must not be in use");
        require(msg.value >= requesterStake, "This is not enough to cover initial stake");
        slot.used = true;
        slot.processType = ProcessType.Removal;
        slot.beingDisputed = false;
        slot.submissionTime = uint72(block.timestamp);
        slot.requester = msg.sender;
        emit ItemRemovalRequest(_workSlot, _idSlot, _idSubmissionTime);
    }
    
    function executeRequest(uint _slotIndex) public {
        Slot storage slot = slots[_slotIndex];
        require(slotIsExecutable(slot), "Slot cannot be executed");
        // it will be executed now
        slot.used = false;
        payable(slot.requester).transfer(requesterStake);
        if (slot.processType == ProcessType.Add) {
            emit ItemAdded(_slotIndex);
        }
        else {
            emit ItemRemoved(_slotIndex);
        }
    }
    
    
    // VIEW FUNCTIONS
    
    // relying on this on active contracts could result on users colliding on same slot
    // user which is late will have the transaction cancelled, but gas wasted and unhappy ux
    function firstFreeSlot() view public returns (uint) {
        uint i = 0;
        while (slots[i].used) {
            i = i + 1;
        }
        return i;
    }
    
    // debugging purposes, for now. shouldn't be too expensive and could be useful in future, tho
    // doesn't actually "count" the slots, just checks until there's a virgin slot
    // it's the same as "maxSlots" in the notes
    function firstVirginSlot() view public returns (uint) {
        uint i = 0;
        while (slots[i].requester != address(0)){
            i = i + 1;
        }
        return i;
    }
    
    // this is prob bloat. based on the idea of generating a random free slot, to avoid collisions.
    // could be used to advice the users to wait until there's free slot for gas savings.
    function countFreeSlots() view public returns (uint) {
        uint slotCount = firstVirginSlot();
        uint i = 0;
        uint freeSlots = 0;
        for (; i < slotCount; i++) {
            Slot storage slot = slots[i];
            if (!slot.used) {
                freeSlots++;
            }
        }
        return freeSlots;
    }
    
    function viewSlot(uint _slotIndex) view public returns (Slot memory) {
        return slots[_slotIndex];
    }
    
    function slotIsExecutable(Slot memory _slot) view public returns (bool) {
        bool overSubmissionPeriod = block.timestamp > _slot.submissionTime + submissionPeriod;
        return _slot.used && overSubmissionPeriod && !_slot.beingDisputed;
    }
}