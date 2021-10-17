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
    
    put an option to manually call the function to calculate juror fees and store it locally
    instead of calling an expensive function over contracts every time
    
    in next version with lists etc you could assign ids to "packs"
    "packs" are sets of arbitration data,, msubmissionTime, whatever.
    so you could have many in the same contracts
    anyoen can create packs
    
    put the most used functions (add, remove item) as first functions because that
    makes it cheaper
    
    it is my moral obligation to use uint ipfsHash instead of string. it saves so much gas.
    now it costs 30k.
    

*/

contract SlotCurate {
    
    enum ProcessType {
        Add,
        Removal
    }
    
    enum Party {
        Requester,
        Challenger
    }
    
    struct ListSettings {
        uint requestPeriod;
        uint requesterStake;
        uint challengerStake;
        //  store arbitrator?
        //  store extraData?!?!
    }
    
    struct List {
        uint32 settingsId;
        address governor; // governors can change governor of the list, and change settingsId
        uint64 freeSpace;
    }
    
    // you can compress the bools / enums into a byte variable.
    // that + uint32 timestamp, means there are 7 vacant bytes per slot.
    // but we only need to know the slot to identify the dispute, so why bother?
    // if ids turn out to be needed, that's fine, there's enough space.
    // update:
    // because in new version we store settingsId in the Slot... hmm
    // lets encode settings with uint32 to make attacks unfeasible.
    // you have to store settingsId to stop ongoing Slot to change the settings
    // so there are 2 free bytes right now.
    
    struct Slot {
        bool used;
        ProcessType processType;
        bool beingDisputed;
        uint32 settingsId;
        uint40 requestTime; // overflow in 37k years
        address requester;
    }
    
    // all bounded data related to the Dispute. unbounded data such as contributions is handled out
    // todo
    struct Dispute {
        uint256 disputeId; // there's no way around this
        uint32 slot; // flexible
        uint32 nContributions; // flexible
        
    }
    
    /* it's pretty tight. we want 256 bits per Contribution, but address only leaves
    // 96 bits for amount + data
    // if we want to split contributions based on rounds
    // 1. if rounds increase exponentially, then a uint8 to encode round + party is enough.
    // Still, the main problem is that it doesn't leave much for amount
    // current ETH can be counted with 87 bits. uint88 will top any amount of ETH for a long time.
    // uint80 is not acceptable. (will be like this temporarily until I change it)
    // you could also encode everything in the 96 remaining bits, and take,
    // 1 bit for Party, ~6 for round, and give an extra bit to the amount?
        you could also not store round at all, and distribute rewards
        proportionally disregarding rounds.
    // actually, just raise everything something like 16 bits so you have to store 16 less bits.
    // who cares about digital dust am i right
    */
    struct Contribution {
        uint8 round;
        Party party;
        uint80 amount; // to be raised 16 bits.
        address contributor;
    }
    
    // EVENTS //
    
    event ItemAddRequest(uint _slotIndex, uint _ipfsUri);
    event ItemAdded(uint _slotIndex);
    event ItemRemovalRequest(uint _workSlot, uint _idSlot, uint _idRequestTime);
    event ItemRemoved(uint _slotIndex);
    
    
    // CONTRACT STORAGE //
    // these cannot be changed after deployment.
    // might actually become changable? but only if there's enough space available in the slots
    uint immutable requestPeriod;
    uint immutable requesterStake;
    uint immutable challengerStake;
    
    mapping(uint256 => Slot) slots;
    mapping(uint256 => Dispute) disputes;
    mapping(uint32 => ListSettings) listSettings; // encoded with uint32 to make an attack unfeasible
    mapping(uint256 => mapping(uint256 => Contribution)) contributions; // contributions[disputeSlot][n]
    
    constructor(uint _requestPeriod, uint _requesterStake, uint _challengerStake) {
        requestPeriod = _requestPeriod;
        requesterStake = _requesterStake;
        challengerStake = _challengerStake;
    }
    
    // PUBLIC FUNCTIONS
    
    // lists
    
    // no refunds for overpaying. consider it burned. refunds are bloat.
    function addItem(uint _slotIndex, uint _ipfsUri) public payable {
        Slot storage slot = slots[_slotIndex];
        require(slot.used == false, "Slot must not be in use");
        require(msg.value >= requesterStake, "This is not enough to cover initial stake");
        slot.used = true;
        slot.processType = ProcessType.Add;
        slot.beingDisputed = false;
        slot.requestTime = uint40(block.timestamp);
        slot.requester = msg.sender;
        emit ItemAddRequest(_slotIndex, _ipfsUri);
    }
    
    function removeItem(uint _workSlot, uint _idSlot, uint _idRequestTime) public payable {
        Slot storage slot = slots[_workSlot];
        require(slot.used == false, "Slot must not be in use");
        require(msg.value >= requesterStake, "This is not enough to cover initial stake");
        slot.used = true;
        slot.processType = ProcessType.Removal;
        slot.beingDisputed = false;
        slot.requestTime = uint40(block.timestamp);
        slot.requester = msg.sender;
        emit ItemRemovalRequest(_workSlot, _idSlot, _idRequestTime);
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
        bool overRequestPeriod = block.timestamp > _slot.requestTime + requestPeriod;
        return _slot.used && overRequestPeriod && !_slot.beingDisputed;
    }
    
    function slotCanBeChallenged(Slot memory _slot) view public returns (bool) {
        bool overRequestPeriod = block.timestamp > _slot.requestTime + requestPeriod;
        return _slot.used && !overRequestPeriod && !_slot.beingDisputed;
    }
}