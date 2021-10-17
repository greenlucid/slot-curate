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
    
    ItemRemoved and ItemAdded are the same contract wise
    An optimization would be to just have an SlotExecuted with the slot and the enum
    So there are no branches figuring out which one, and it's slightly cheaper to deploy.
    
    put an option to manually call the function to calculate juror fees and store it locally
    instead of calling an expensive function over contracts every time
    this would get harder if we store arbitrator / arbextradata separately
    
    put the most used functions (add, remove item) as first functions because that
    makes it cheaper

    with rollups it is very important to compress function args
    consider making:
    slot uint64
    listId uint64
    settings being an uint32 may provide surface attack. a spammer could spam
    and create tons of settings so that no new settings could be ever created.
    4B of settings at 150k per creation can hold 17 years of having all blocks fully creating settings.
    with so much time and so many settings, maybe there's a few useful ones?

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
    
    struct Settings {
        uint requestPeriod;
        uint requesterStake;
        uint challengerStake;
        //  store arbitrator?
        //  store extraData?!?!
    }
    
    struct List {
        bool created;
        uint32 settingsId;
        address governor; // governors can change governor of the list, and change settingsId
        uint56 freeSpace;
    }
    
    // if you compress bools and enum into 1 byte
    // 2 vacant bytes    
    struct Slot {
        bool used;
        ProcessType processType;
        bool beingDisputed;
        uint32 settingsId; // to discourage settings spam attack. maybe put the 2 bytes here.
        uint40 requestTime; // overflow in 37k years
        address requester;
    }
    
    // all bounded data related to the Dispute. unbounded data such as contributions is handled out
    // todo
    struct Dispute {
        uint256 disputeId; // there's no way around this
        uint64 slot; // flexible
        uint32 nContributions; // flexible
    }
    
    struct Contribution {
        uint8 round;
        Party party;
        uint80 amount; // to be raised 16 bits.
        address contributor;
    }
    
    // EVENTS //
    
    event ItemAddRequest(uint _slotIndex, string _ipfsUri);
    event ItemAdded(uint _slotIndex);
    event ItemRemovalRequest(uint _workSlot, uint _idSlot, uint _idRequestTime);
    event ItemRemoved(uint _slotIndex);
    
    
    // CONTRACT STORAGE //
    uint64 listCount;
    uint32 settingsCount; // to prevent from assigning invalid settings to lists.

    mapping(uint64 => Slot) slots;
    mapping(uint256 => Dispute) disputes;
    mapping(uint64 => List) lists;
    mapping(uint32 => Settings) settingsMap; // encoded with uint32 to make an attack unfeasible
    mapping(uint256 => mapping(uint256 => Contribution)) contributions; // contributions[disputeSlot][n]
    
    constructor() {
    }
    
    // PUBLIC FUNCTIONS
    
    // lists
    
    // no refunds for overpaying. consider it burned. refunds are bloat.
    function addItem(uint64 _listIndex, uint64 _slotIndex, string memory _ipfsUri) public payable {
        Slot storage slot = slots[_slotIndex];
        require(slot.used == false, "Slot must not be in use");
        List storage list = lists[_listIndex];
        require(list.created, "List must have been created");
        Settings storage settings = settingsMap[list.settingsId];
        require(msg.value >= settings.requesterStake, "This is not enough to cover initial stake");
        slot.used = true;
        slot.settingsId = list.settingsId;
        slot.processType = ProcessType.Add;
        slot.beingDisputed = false;
        slot.requestTime = uint40(block.timestamp);
        slot.requester = msg.sender;
        emit ItemAddRequest(_slotIndex, _ipfsUri);
    }
    
    function removeItem(uint64 _workSlot, uint64 _listIndex, uint _idSlot, uint _idRequestTime) public payable {
        Slot storage slot = slots[_workSlot];
        require(slot.used == false, "Slot must not be in use");
        List storage list = lists[_listIndex];
        require(list.created, "List must have been created");
        Settings storage settings = settingsMap[list.settingsId];
        require(msg.value >= settings.requesterStake, "This is not enough to cover initial stake");
        slot.used = true;
        slot.settingsId = list.settingsId;
        slot.processType = ProcessType.Removal;
        slot.beingDisputed = false;
        slot.requestTime = uint40(block.timestamp);
        slot.requester = msg.sender;
        emit ItemRemovalRequest(_workSlot, _idSlot, _idRequestTime);
    }
    
    function executeRequest(uint64 _slotIndex) public {
        Slot storage slot = slots[_slotIndex];
        require(slotIsExecutable(slot), "Slot cannot be executed");
        // it will be executed now
        slot.used = false;
        Settings storage settings = settingsMap[slot.settingsId];
        payable(slot.requester).transfer(settings.requesterStake);
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
        uint64 i = 0;
        while (slots[i].used) {
            i = i + 1;
        }
        return i;
    }
    
    // debugging purposes, for now. shouldn't be too expensive and could be useful in future, tho
    // doesn't actually "count" the slots, just checks until there's a virgin slot
    // it's the same as "maxSlots" in the notes
    function firstVirginSlot() view public returns (uint) {
        uint64 i = 0;
        while (slots[i].requester != address(0)){
            i = i + 1;
        }
        return i;
    }
    
    // this is prob bloat. based on the idea of generating a random free slot, to avoid collisions.
    // could be used to advice the users to swait until there's free slot for gas savings.
    function countFreeSlots() view public returns (uint) {
        uint slotCount = firstVirginSlot();
        uint64 i = 0;
        uint freeSlots = 0;
        for (; i < slotCount; i++) {
            Slot storage slot = slots[i];
            if (!slot.used) {
                freeSlots++;
            }
        }
        return freeSlots;
    }
    
    function viewSlot(uint32 _slotIndex) view public returns (Slot memory) {
        return slots[_slotIndex];
    }
    
    function slotIsExecutable(Slot memory _slot) view public returns (bool) {
        Settings storage settings = settingsMap[_slot.settingsId];
        bool overRequestPeriod = block.timestamp > _slot.requestTime + settings.requestPeriod;
        return _slot.used && overRequestPeriod && !_slot.beingDisputed;
    }
    
    function slotCanBeChallenged(Slot memory _slot) view public returns (bool) {
        Settings storage settings = settingsMap[_slot.settingsId];
        bool overRequestPeriod = block.timestamp > _slot.requestTime + settings.requestPeriod;
        return _slot.used && !overRequestPeriod && !_slot.beingDisputed;
    }
}