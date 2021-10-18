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
    maybe not. the only way to tell is to go and actually try it.
    
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

    // adding the list requires made it SUPER expensive.
    // now it's 38k to add item. not acceptable.
    // what ill do instead is, just verify it on the subgraph instead.
    // if user posts list that doesn't exist, or posts settings that are not the current settings of that list
    // then subgraph will act as if item didn't exist. or, maybe track it but as an invalid item.
    // this means, now you have to submit the settings in the args...?
    // maybe instead submit list, do the extra read but don't do require.
    yup. that removed 4k cost, just like that.
    now 50.6k to create initially, and 33545 in used slot.
    if settings not in args, 52.4k initially and 35186 in used slot.
    changing the order: 52286, 
    AND means you can do it by only verifying list exists in subgraph.
    and i wasn't even verifying minimum stake... yeah seems like it's up to 35.4k again.

    ideas for the future:
    not even store all data to verify the process on chain. you could let invalid process on chain
    just exist and finish, and ignore them.
    you could even not store the lists logic at all, make them just be another item submission, somehow.
    again, the terms will be stored off chain, so whoever doesn't play by the rules is just ignored
    and you let their process exist and do whatever.

    maybe, do the same thing I'm doing but put some assembly level optimizations
    since I can tell the compiler is messing up the order of the calls and wasting gas.
    would make it hard to audit.
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
    
    // settings cannot be mutated once created
    struct Settings {
        // you don't need to store created
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
        uint256 arbitratorDisputeId; // there's no way around this
        bool used;
        uint64 slotId; // flexible
        uint32 nContributions; // flexible
    }
    
    struct Contribution {
        uint8 round;
        Party party;
        uint80 amount; // to be raised 16 bits.
        address contributor;
    }
    
    // EVENTS //
    
    event ListCreated(uint64 _listIndex, uint32 _settingsId, address _governor, string _ipfsUri);
    event ListUpdated(uint64 _listIndex, uint32 _settingsId, address _governor);
    event SettingsCreated(uint _requestPeriod, uint _requesterStake, uint _challengerStake);
    event ItemAddRequest(uint64 _listIndex, uint64 _slotIndex, string _ipfsUri);
    event ItemAdded(uint64 _slotIndex);
    event ItemRemovalRequest(uint64 _workSlot, uint32 _settingsId, uint64 _idSlot, uint40 _idRequestTime);
    event ItemRemoved(uint64 _slotIndex);
    
    
    // CONTRACT STORAGE //
    uint64 listCount;
    uint32 settingsCount; // to prevent from assigning invalid settings to lists.

    mapping(uint64 => Slot) slots;
    mapping(uint64 => Dispute) disputes;
    mapping(uint64 => List) lists;
    mapping(uint32 => Settings) settingsMap; // encoded with uint32 to make an attack unfeasible
    mapping(uint256 => mapping(uint256 => Contribution)) contributions; // contributions[disputeSlot][n]
    
    constructor() {
    }
    
    // PUBLIC FUNCTIONS
    
    // lists
    function createList(address _governor, uint32 _settingsId, string memory _ipfsUri) public {
        require(_settingsId < settingsCount, "Settings must exist");
        List storage list = lists[listCount++];
        list.governor = _governor;
        list.settingsId = _settingsId;
        emit ListCreated(listCount - 1, _settingsId, _governor, _ipfsUri);
    }

    function updateList(uint64 _listIndex, uint32 _settingsId, address _newGovernor) public {
        List storage list = lists[_listIndex];
        require(msg.sender == list.governor, "You need to be the governor");
        list.governor = _newGovernor;
        list.settingsId = _settingsId;
        emit ListUpdated(_listIndex, _settingsId, _newGovernor);
    }

    // settings
    // bit of a draft since I havent done the dispute side of things yet
    function createSettings(uint _requestPeriod, uint _requesterStake, uint _challengerStake) public {
        // put safeguard check? for checking if settingsCount is -1.
        require(settingsCount != 4294967295, "Max settings reached"); // there'd be 4.3B so please just reuse one
        Settings storage settings = settingsMap[settingsCount++];
        settings.requestPeriod = _requestPeriod;
        settings.requesterStake = _requesterStake;
        settings.challengerStake = _challengerStake;
        emit SettingsCreated(_requestPeriod, _requesterStake, _challengerStake);
    }
    
    // no refunds for overpaying. consider it burned. refunds are bloat.

    // you could add an "emergency" boolean option.
    // if on, and the chosen slotIndex is taken, it will look for the first unused slot and create there instead.
    // otherwise, the transaction fails. it's important to have it optional this since there could potentially be a lot of
    // taken slots.
    // but its important to have to option as safeguard in case frontrunners try to inhibit the protocol.
    // another way is making a separate wrapper public function for this, that calls the two main ones
    // (make one for add and another for remove. and another one for challenging (to get free dispute slot))

    // in the contract, listIndex and settingsId are trusted.
    // but in the subgraph, if listIndex doesnt exist or settings are not really the ones on list
    // then item will be ignored or marked as invalid.
    function addItem(uint64 _listIndex, uint32 _settingsId, uint64 _slotIndex, string memory _ipfsUri) public payable {
        Slot storage slot = slots[_slotIndex];
        require(slot.used == false, "Slot must not be in use");
        Settings storage settings = settingsMap[_settingsId];
        require(msg.value >= settings.requesterStake, "This is not enough to cover initil stake");
        slot.settingsId = _settingsId;
        slot.used = true;
        slot.processType = ProcessType.Add;
        slot.beingDisputed = false;
        slot.requestTime = uint40(block.timestamp);
        slot.requester = msg.sender;
        emit ItemAddRequest(_listIndex, _slotIndex, _ipfsUri);
    }
    
    // list is checked in subgraph. settings is trusted here.
    // if settings was not the one settings in subgraph at the time,
    // then subgraph will ignore the removal (so it has no effect when exec.)
    // could even be challenged as an ilegal request to extract the stake, if significant.
    function removeItem(uint64 _workSlot, uint32 _settingsId, uint64 _idSlot, uint40 _idRequestTime) public payable {
        Slot storage slot = slots[_workSlot];
        require(slot.used == false, "Slot must not be in use");
        Settings storage settings = settingsMap[_settingsId];
        require(msg.value >= settings.requesterStake, "This is not enough to cover requester stake");
        slot.settingsId = _settingsId;
        slot.used = true;
        slot.processType = ProcessType.Removal;
        slot.beingDisputed = false;
        slot.requestTime = uint40(block.timestamp);
        slot.requester = msg.sender;
        emit ItemRemovalRequest(_workSlot, _settingsId, _idSlot, _idRequestTime);
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

    function challengeRequest(uint64 _slotIndex, uint64 _disputeSlot) public payable {
        Slot storage slot = slots[_slotIndex];
        require(slotCanBeChallenged(slot), "Slot cannot be challenged");
        Settings storage settings = settingsMap[slot.settingsId];
        require(msg.value >= settings.challengerStake, "This is not enough to cover challenger stake");
        Dispute storage dispute = disputes[_disputeSlot];
        require(!dispute.used, "That dispute slot is being used");

        slot.beingDisputed = true;
        // it will be challenged now

        // arbitrator magic happens here (pay fees, maybe read how much juror fees are...)
        // and get disputeId so that you can store it, you know.

        dispute.used = true;
        dispute.nContributions = 1; // storing requester is a waste. just compute it separately
        dispute.slotId = _slotIndex;
    }

    // rule:
    /*
        because disputeId is stored in the dispute slots,
        but rule doesn't know in which dispute slot it is stored, 
        there are 2 ways to go about this:
        
        the O(n) way: just read all disputes until you find
        disputeId == _disputeId
        and execute the action there.
        could be cheaper, but cost grows as the number of slots grows
        (and might be subject to attack)

        the storage way: store the ruling in Rulings[disputeId], along with a timestamp.
        and just have another func "executeRuling" separately, on the dispute. the dispute slot know the disputeId,
        but the disputeId doesn't know the dispute slot.
        has a fixed cost of ~45k, such is life.
    */
    
    
    // VIEW FUNCTIONS
    
    // relying on this by itself could result on users colliding on same slot
    // user which is late will have the transaction cancelled, but gas wasted and unhappy ux
    // could be used to make an "emergency slot", in case your slot submission was in an used slot.
    // will get the first Virgin, or Created slot.
    function firstFreeSlot(uint64 _startPoint) view public returns (uint64) {
        uint64 i = _startPoint;
        while (slots[i].used) {
            i = i + 1;
        }
        return i;
    }
    
    // debugging purposes, for now. shouldn't be too expensive and could be useful in future, tho
    // doesn't actually "count" the slots, just checks until there's a virgin slot
    // it's the same as "maxSlots" in the notes
    function firstVirginSlotFrom(uint64 _startPoint) view public returns (uint64) {
        uint64 i = _startPoint;
        while (slots[i].requester != address(0)){
            i = i + 1;
        }
        return i;
    }
    
    // this is prob bloat. based on the idea of generating a random free slot, to avoid collisions.
    // could be used to advice the users to wait until there's free slot for gas savings.
    function countFreeSlots() view public returns (uint64) {
        uint64 slotCount = firstVirginSlotFrom(0);
        uint64 i = 0;
        uint64 freeSlots = 0;
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